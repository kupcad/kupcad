<!--
  @component
  The viewer for Svelte: a canvas filling its box, showing `model` in the state its props give.
  `selected` is bindable (a click on a part sets it), and so is `viewer`, the Viewer itself, for
  what isn't state: framing a view (`setCamera({ view })`), `fit()`, `screenshot()`.
-->
<script>
  import { onMount } from 'svelte';
  import { Viewer } from './viewer.js';

  /** @import { Model } from '@kupcad/protocol/types' */
  /** @import { Environment, Projection, RenderMode, Section, Theme, ViewerOptions } from './types.js' */

  /**
   * @typedef {object} Props
   * @property {Model | null} [model]
   * @property {Theme} [theme]
   * @property {Environment} [environment]
   * @property {RenderMode} [renderMode]
   * @property {Projection} [projection]
   * @property {Section | null} [section]
   * @property {string | null} [selected] the part selected; bindable
   * @property {Viewer | null} [viewer] the Viewer, once mounted; bindable
   * @property {ViewerOptions} [options] what the Viewer is made with (its renderer, Draco's path)
   * @property {string} [label] what the canvas is, for a screen reader
   * @property {(viewer: Viewer) => void} [onmodel] a model is shown: what follows it (its
   *   bounds) can be read
   * @property {(error: unknown) => void} [onerror] a model it couldn't show; without it, the
   *   error is thrown on, unhandled
   */

  /** @type {Props} */
  let {
    model = null,
    theme,
    environment = 'grid',
    renderMode = 'solid',
    projection = 'perspective',
    section = null,
    selected = $bindable(null),
    viewer = $bindable(null),
    options = {},
    label = 'The model',
    onmodel,
    onerror,
  } = $props();

  /** @type {HTMLCanvasElement} */
  let canvas;

  onMount(() => {
    const made = new Viewer(canvas, { ...options, theme: theme ?? options.theme, environment });
    const resized = new ResizeObserver(() => made.resize());
    resized.observe(canvas);
    made.addEventListener('select', (event) => {
      selected = /** @type {CustomEvent<{ part: string | null }>} */ (event).detail.part;
    });
    viewer = made;
    return () => {
      resized.disconnect();
      made.dispose();
      viewer = null;
    };
  });

  $effect(() => {
    const shown = viewer;
    shown?.setModel(model).then(
      () => onmodel?.(shown),
      (error) => {
        if (!onerror) throw error;
        onerror(error);
      },
    );
  });
  $effect(() => {
    if (theme) viewer?.setTheme(theme);
  });
  $effect(() => {
    viewer?.setEnvironment(environment);
  });
  $effect(() => {
    viewer?.setRenderMode(renderMode);
  });
  $effect(() => {
    viewer?.setCamera({ projection });
  });
  $effect(() => {
    viewer?.setSection(section);
  });
  $effect(() => {
    if (viewer && viewer.selected !== selected) viewer.select(selected);
  });
</script>

<canvas bind:this={canvas} class="kc-viewer" aria-label={label}></canvas>

<style>
  .kc-viewer {
    display: block;
    width: 100%;
    height: 100%;
    touch-action: none;
  }
</style>
