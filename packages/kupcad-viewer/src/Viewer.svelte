<!--
  @component
  The viewer for Svelte: a canvas filling its box, showing `model` in the state its props give,
  with a view cube in its corner (`cube`). `selected` is bindable (a click on a part sets it),
  and so is `viewer`, the Viewer itself, for what isn't state: framing a view
  (`setCamera({ view })`), `fit()`, `screenshot()`.
-->
<script>
  import { onMount, untrack } from 'svelte';
  import { ViewCube } from './view-cube.js';
  import { Viewer } from './viewer.js';

  /** @import { Model } from '@kupcad/protocol/types' */
  /** @import { Environment, Projection, RenderMode, Section, Theme, ViewerOptions } from './types.js' */

  /**
   * @typedef {object} Props
   * @property {Model | null} [model]
   * @property {Theme} [theme]
   * @property {Environment} [environment]
   * @property {RenderMode} [renderMode]
   * @property {boolean} [edges] the shapes' edges are drawn (by default; a wireframe's always are)
   * @property {boolean} [axes] the axes through the origin are drawn (by default)
   * @property {Projection} [projection]
   * @property {Section | null} [section]
   * @property {string | null} [selected] the part selected; bindable
   * @property {Viewer | null} [viewer] the Viewer, once mounted; bindable
   * @property {ViewerOptions} [options] what the Viewer is made with (its renderer, Draco's path)
   * @property {string} [label] what the canvas is, for a screen reader
   * @property {boolean} [cube] the view cube is shown in the corner (by default)
   * @property {(viewer: Viewer) => void} [onmodel] a model is shown: what follows it (its
   *   bounds) can be read. Not for one a later model replaced before it was shown
   * @property {(error: unknown) => void} [onerror] a model it couldn't show; without it, the
   *   error is thrown on, unhandled
   */

  /** @type {Props} */
  let {
    model = null,
    theme,
    environment = 'grid',
    renderMode = 'solid',
    edges = true,
    axes = true,
    projection = 'perspective',
    section = null,
    selected = $bindable(null),
    viewer = $bindable(null),
    options = {},
    label = 'The model',
    cube = true,
    onmodel,
    onerror,
  } = $props();

  /** @type {HTMLCanvasElement} */
  let canvas;
  /** @type {HTMLCanvasElement | undefined} */
  let cubeCanvas = $state();
  /** @type {ViewCube | null} */
  let viewCube = null;
  /** The Viewer made, which the effects follow: `viewer` is the host's to bind, and may be set. */
  let made = $state(/** @type {Viewer | null} */ (null));

  onMount(() => {
    const shown = new Viewer(canvas, { ...options, theme: theme ?? options.theme, environment });
    const resized = new ResizeObserver(() => shown.resize());
    resized.observe(canvas);
    shown.addEventListener('select', (event) => {
      selected = /** @type {CustomEvent<{ part: string | null }>} */ (event).detail.part;
    });
    made = shown;
    viewer = shown;
    return () => {
      resized.disconnect();
      shown.dispose();
      made = null;
      viewer = null;
    };
  });

  // The cube follows the viewer: made with it, on its own canvas, in the theme then (another
  // theme is drawn in by the effect below, not by a cube made again)
  $effect(() => {
    const shown = made;
    const on = cubeCanvas;
    if (!shown || !on) return;
    const shownCube = untrack(
      () => new ViewCube(on, shown, { theme: theme ?? options.theme, renderer: options.renderer }),
    );
    const resized = new ResizeObserver(() => shownCube.resize());
    resized.observe(on);
    viewCube = shownCube;
    return () => {
      resized.disconnect();
      shownCube.dispose();
      viewCube = null;
    };
  });

  $effect(() => {
    const shown = made;
    shown?.setModel(model).then(
      (isShown) => {
        if (isShown) onmodel?.(shown);
      },
      (error) => {
        if (!onerror) throw error;
        onerror(error);
      },
    );
  });
  $effect(() => {
    if (!theme) return;
    made?.setTheme(theme);
    viewCube?.setTheme(theme);
  });
  $effect(() => {
    made?.setEnvironment(environment);
  });
  $effect(() => {
    made?.setRenderMode(renderMode);
  });
  $effect(() => {
    made?.setEdges(edges);
  });
  $effect(() => {
    made?.setAxes(axes);
  });
  $effect(() => {
    made?.setCamera({ projection });
  });
  $effect(() => {
    made?.setSection(section);
  });
  $effect(() => {
    if (made && made.selected !== selected) made.select(selected);
  });
</script>

<div class="kc-viewer">
  <canvas bind:this={canvas} class="scene" aria-label={label}></canvas>
  {#if cube}
    <canvas
      bind:this={cubeCanvas}
      class="cube"
      aria-label="View cube: a face, an edge or a corner clicked looks from there"
    ></canvas>
  {/if}
</div>

<style>
  .kc-viewer {
    position: relative;
    width: 100%;
    height: 100%;
  }
  .scene {
    display: block;
    width: 100%;
    height: 100%;
    touch-action: none;
  }
  .cube {
    position: absolute;
    top: 8px;
    right: 8px;
    width: 96px;
    height: 96px;
  }
</style>
