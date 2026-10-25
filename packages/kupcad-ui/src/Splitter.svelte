<!--
  @component
  The bar between two panes, which resizes one of them: dragged, or with the arrow keys (by
  16 px, 64 with Shift; Home and End for its least and most), and double-clicked back to the
  size it started with. `size` (bindable) is the pane's width for a bar between columns, its
  height for one between rows, in CSS pixels, kept between `min` and `max`; the pane is the one
  before the bar or after it (`pane`). `onchange` gets the size once a drag or a key is done,
  for the host to keep.
-->
<script>
  import { untrack } from 'svelte';

  /**
   * @typedef {object} Props
   * @property {number} size the pane's size; bindable
   * @property {'columns' | 'rows'} [between] what the bar is between
   * @property {'before' | 'after'} [pane] which pane it sizes: the one before it (left, above)
   *   or after it
   * @property {number} [min]
   * @property {number} [max]
   * @property {string} label what it resizes, for a screen reader
   * @property {(size: number) => void} [onchange]
   */

  /** @type {Props} */
  let {
    size = $bindable(),
    between = 'columns',
    pane = 'before',
    min = 120,
    max = Number.POSITIVE_INFINITY,
    label,
    onchange,
  } = $props();

  /** A key's step, and with Shift. */
  const STEP = 16;
  const LONG_STEP = 64;
  const first = untrack(() => size);
  /** Where a drag started: the pointer, and the size then. */
  let drag = $state(/** @type {{ at: number, from: number } | null} */ (null));

  const clamp = (/** @type {number} */ value) =>
    Math.round(Math.min(Math.max(value, min), Math.max(min, max)));
  /** +1 when moving right (or down) grows the pane, -1 when it shrinks it. */
  const sign = $derived(pane === 'before' ? 1 : -1);
  const along = (/** @type {PointerEvent} */ event) =>
    between === 'columns' ? event.clientX : event.clientY;

  /** @param {number} next */
  function settle(next) {
    size = clamp(next);
    onchange?.(size);
  }

  /** @param {PointerEvent & { currentTarget: HTMLElement }} event */
  function down(event) {
    if (event.button !== 0) return;
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    drag = { at: along(event), from: size };
  }

  /** @param {PointerEvent} event */
  function move(event) {
    if (drag) size = clamp(drag.from + sign * (along(event) - drag.at));
  }

  function up() {
    if (!drag) return;
    drag = null;
    onchange?.(size);
  }

  /** @param {KeyboardEvent} event */
  function key(event) {
    const step = event.shiftKey ? LONG_STEP : STEP;
    const [less, more] =
      between === 'columns' ? ['ArrowLeft', 'ArrowRight'] : ['ArrowUp', 'ArrowDown'];
    if (event.key === less) settle(size - sign * step);
    else if (event.key === more) settle(size + sign * step);
    else if (event.key === 'Home') settle(min);
    else if (event.key === 'End' && Number.isFinite(max)) settle(max);
    else return;
    event.preventDefault();
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions (a focusable separator is ARIA's splitter, a widget) -->
<div
  class="kc-splitter {between}"
  class:dragging={drag !== null}
  role="separator"
  tabindex="0"
  aria-label={label}
  aria-orientation={between === 'columns' ? 'vertical' : 'horizontal'}
  aria-valuenow={size}
  aria-valuemin={min}
  aria-valuemax={Number.isFinite(max) ? max : undefined}
  onpointerdown={down}
  onpointermove={move}
  onpointerup={up}
  onpointercancel={up}
  onkeydown={key}
  ondblclick={() => settle(first)}
></div>

<style>
  /* No room of its own: the panes keep their borders, and the bar lies over the one between
     them, a grip wider than it, which shows its line when used */
  .kc-splitter {
    position: relative;
    flex: none;
    z-index: 1;
    touch-action: none;
    outline: none;
  }
  .columns {
    width: 0;
    cursor: col-resize;
  }
  .rows {
    height: 0;
    cursor: row-resize;
  }
  .kc-splitter::before,
  .kc-splitter::after {
    content: '';
    position: absolute;
  }
  .columns::after {
    inset: 0 -4px;
  }
  .rows::after {
    inset: -4px 0;
  }
  .columns::before {
    inset: 0 -1px;
  }
  .rows::before {
    inset: -1px 0;
  }
  .kc-splitter:hover::before,
  .kc-splitter:focus-visible::before,
  .dragging::before {
    background: var(--kc-accent);
  }
</style>
