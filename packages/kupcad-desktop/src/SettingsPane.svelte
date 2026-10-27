<!--
  @component
  The app's settings, a page over the window's workspace, each a row of its name and its
  control: how the app looks (the window's theme, the system's by default, or light or dark; the
  editor's font size), how it keeps the person's files (the last folder opened again at the
  start; a script saved a moment after each change, off by default), how a model is shown (the
  view's render mode, projection, floor, edges and axes: the keys the preview's own toolbar
  sets, so either follows the other at once), and whether the console shows under the model.
  Each is read from the app's reactive `settings`, and set there as it is chosen; the close
  button gives the window back.
-->
<script>
  import { ENVIRONMENTS, PROJECTIONS, RENDER_MODES, VIEW_KEYS, viewChoices } from '@kupcad/ui';
  import { FONT_SIZES, fontSizeOf, KEYS } from './prefs.js';
  import { THEMES, themeOf } from './theme.js';

  /** @import { Settings } from '@kupcad/ui' */

  /**
   * @typedef {object} Props
   * @property {Settings} settings the app's, reactive
   * @property {() => void} onclose
   */

  /** @type {Props} */
  let { settings, onclose } = $props();

  const id = $props.id();

  const theme = $derived(themeOf(settings.get(KEYS.theme)));
  const fontSize = $derived(fontSizeOf(settings.get(KEYS.fontSize)));
  const reopen = $derived(settings.get(KEYS.reopen) !== false);
  const autosave = $derived(settings.get(KEYS.autosave) === true);
  const showsConsole = $derived(settings.get(KEYS.console) !== false);
  const view = $derived(viewChoices(settings));

  /** What each choice of the view is called. @type {Record<string, string>} */
  const LABELS = {
    solid: 'Solid',
    xray: 'X-ray',
    wireframe: 'Wireframe',
    perspective: 'Perspective',
    orthographic: 'Orthographic',
    grid: 'Grid',
    plate: 'Plate',
    none: 'None',
  };
</script>

<!-- One choice of a few, side by side: `key`'s value in the settings -->
{#snippet choices(
  /** @type {string} */ key,
  /** @type {string} */ title,
  /** @type {readonly (readonly [value: string, label: string])[]} */ options,
  /** @type {string} */ chosen,
  /** @type {string} */ hint,
)}
  <div class="row">
    <span class="name" id="{id}-{key}">{title}</span>
    <div>
      <div
        class="segments"
        role="radiogroup"
        aria-labelledby="{id}-{key}"
        aria-describedby={hint ? `${id}-${key}-hint` : undefined}
      >
        {#each options as [value, label] (value)}
          <label>
            <input
              type="radio"
              name="{id}-{key}"
              {value}
              checked={chosen === value}
              onchange={() => settings.set(key, value)}
            />
            <span>{label}</span>
          </label>
        {/each}
      </div>
      {#if hint}<p class="hint" id="{id}-{key}-hint">{hint}</p>{/if}
    </div>
  </div>
{/snippet}

<!-- A setting on or off: `key`'s value in the settings -->
{#snippet toggle(
  /** @type {string} */ key,
  /** @type {string} */ title,
  /** @type {string} */ label,
  /** @type {boolean} */ on,
)}
  <div class="row">
    <span class="name">{title}</span>
    <label class="check">
      <input
        type="checkbox"
        class="kc-check"
        checked={on}
        onchange={(event) => settings.set(key, event.currentTarget.checked)}
      />
      {label}
    </label>
  </div>
{/snippet}

<div class="page">
  <header>
    <h2>Settings</h2>
    <button
      type="button"
      class="close"
      aria-label="Close settings"
      title="Close (Esc)"
      onclick={onclose}
    >
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
    </button>
  </header>

  <section>
    <h3>Appearance</h3>
    {@render choices(
      KEYS.theme,
      'Theme',
      THEMES,
      theme,
      "System follows your computer's appearance.",
    )}
    <div class="row">
      <label class="name" for="{id}-font">Editor font size</label>
      <select
        id="{id}-font"
        class="kc-control"
        value={fontSize}
        onchange={(event) => settings.set(KEYS.fontSize, Number(event.currentTarget.value))}
      >
        {#each FONT_SIZES as size (size)}
          <option value={size}>{size} px</option>
        {/each}
      </select>
    </div>
  </section>

  <section>
    <h3>Files</h3>
    {@render toggle(KEYS.reopen, 'On start', 'Open the last folder when KupCAD starts', reopen)}
    {@render toggle(
      KEYS.autosave,
      'Autosave',
      'Save a script a moment after each change',
      autosave,
    )}
  </section>

  <section>
    <h3>View</h3>
    <p class="hint lead">How a model is shown. The preview's toolbar changes these too.</p>
    {@render choices(
      VIEW_KEYS.renderMode,
      'Render mode',
      RENDER_MODES.map((mode) => [mode, LABELS[mode]]),
      view.renderMode,
      '',
    )}
    {@render choices(
      VIEW_KEYS.projection,
      'Projection',
      PROJECTIONS.map((projection) => [projection, LABELS[projection]]),
      view.projection,
      '',
    )}
    {@render choices(
      VIEW_KEYS.environment,
      'Floor',
      ENVIRONMENTS.map((environment) => [environment, LABELS[environment]]),
      view.environment,
      '',
    )}
    {@render toggle(VIEW_KEYS.edges, 'Edges', "Draw the shapes' edges", view.edges)}
    {@render toggle(VIEW_KEYS.axes, 'Axes', 'Draw the axes through the origin', view.axes)}
  </section>

  <section>
    <h3>Console</h3>
    {@render toggle(KEYS.console, 'Console', 'Show the console under the model', showsConsole)}
  </section>
</div>

<style>
  /* One column, as wide as a line reads well, in the middle of the window */
  .page {
    max-width: 640px;
    margin: 0 auto;
    padding: 24px 32px;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--kc-border);
  }
  h2 {
    margin: 0;
    font-size: 20px;
    font-weight: 600;
  }
  h3 {
    margin: 24px 0 0;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--kc-muted);
  }
  .close {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    padding: 0;
    color: var(--kc-muted);
    background: none;
    border: none;
    border-radius: var(--kc-radius);
    cursor: pointer;
  }
  .close:hover {
    color: var(--kc-fg);
    background: var(--kc-hover);
  }
  .close:focus-visible {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .close svg {
    width: 18px;
    height: 18px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.75;
    stroke-linecap: round;
  }
  /* A setting: its name on the left, its control and what it does on the right */
  .row {
    display: grid;
    grid-template-columns: 140px 1fr;
    gap: 16px;
    align-items: baseline;
    padding: 12px 0;
    border-bottom: 1px solid var(--kc-border);
  }
  .name {
    font-weight: 600;
  }
  select {
    justify-self: start;
  }
  /* A choice of a few side by side, one control: the radios hidden, their labels the segments */
  .segments {
    display: inline-flex;
    border: 1px solid var(--kc-control-border);
    border-radius: var(--kc-radius);
    overflow: hidden;
  }
  .segments label {
    position: relative;
  }
  .segments label + label {
    border-left: 1px solid var(--kc-control-border);
  }
  .segments input {
    position: absolute;
    width: 1px;
    height: 1px;
    margin: 0;
    opacity: 0;
    pointer-events: none;
  }
  .segments span {
    display: block;
    min-width: 64px;
    padding: 4px 16px;
    text-align: center;
    cursor: pointer;
  }
  .segments label:hover span {
    background: var(--kc-hover);
  }
  /* The one chosen: tinted and edged, as a toggle that is on */
  .segments input:checked + span {
    background: var(--kc-accent-subtle);
    box-shadow: inset 0 0 0 1px var(--kc-accent);
  }
  .segments input:focus-visible + span {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .hint {
    margin: 6px 0 0;
    color: var(--kc-muted);
  }
  .lead {
    margin: 4px 0 4px;
  }
  .check {
    display: flex;
    align-items: center;
    gap: 6px;
    cursor: pointer;
  }
</style>
