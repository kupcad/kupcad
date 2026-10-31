<!--
  @component
  A menu at a point of the page (a tree row's, as `rowMenu` gives it), for a host with no native
  one: in the page's top layer (an auto popover), moved in to stay in the window. It takes the
  focus, on its first item; the arrow keys, Home and End move between its items. Choosing one
  closes it and does what it says; Escape, a click elsewhere or the focus leaving close it with
  nothing done. Closed either way, it says so (`onclose`, for the host to drop it), the focus
  back where it was unless it went elsewhere.
-->
<script>
  import { onMount } from 'svelte';

  /** @import { MenuItem } from './menu.js' */

  /**
   * @typedef {object} Props
   * @property {readonly MenuItem[]} items
   * @property {{ x: number, y: number }} at its top left corner, in the window's pixels (read
   *   as it opens)
   * @property {() => void} onclose
   * @property {string} [label] what it is a menu of, for a screen reader
   */

  /** @type {Props} */
  let { items, at, onclose, label = 'Menu' } = $props();

  /** @type {HTMLDivElement} */
  let bound;
  /** The menu, kept once shown: the browser's events of it may come after it is unmounted. */
  let menu = /** @type {HTMLDivElement | null} */ (null);
  /** What had the focus before it opened. */
  let before = /** @type {Element | null} */ (null);
  let open = false;

  onMount(() => {
    menu = bound;
    before = document.activeElement;
    menu.showPopover();
    open = true;
    const { width, height } = menu.getBoundingClientRect();
    menu.style.left = `${Math.max(0, Math.min(at.x, innerWidth - width))}px`;
    menu.style.top = `${Math.max(0, Math.min(at.y, innerHeight - height))}px`;
    itemsOf()[0]?.focus();
    return close;
  });

  const itemsOf = () => [...(menu?.querySelectorAll('button') ?? [])];

  function close() {
    if (!open) return;
    open = false;
    menu?.hidePopover();
  }

  /** @param {Extract<MenuItem, object>} item */
  function choose(item) {
    close();
    item.action();
  }

  /** Closed, by a choice or the browser (Escape, a click elsewhere). @param {Event} event */
  function toggled(event) {
    if (/** @type {ToggleEvent} */ (event).newState !== 'closed') return;
    open = false;
    const focused = document.activeElement;
    const lost = !focused || focused === document.body || !!menu?.contains(focused);
    if (lost && before instanceof HTMLElement && before.isConnected) before.focus();
    onclose();
  }

  /** @param {KeyboardEvent} event */
  function keydown(event) {
    const all = itemsOf();
    const focused = all.indexOf(/** @type {HTMLButtonElement} */ (document.activeElement));
    const next = {
      ArrowDown: (focused + 1) % all.length,
      ArrowUp: (focused - 1 + all.length) % all.length,
      Home: 0,
      End: all.length - 1,
    }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    all[next]?.focus();
  }

  /** The focus left it (Tab, a click on something that takes it): it closes. @param {FocusEvent} event */
  function focusout(event) {
    if (!menu?.contains(/** @type {Node | null} */ (event.relatedTarget))) close();
  }
</script>

<div
  bind:this={bound}
  class="kc-menu"
  popover="auto"
  role="menu"
  tabindex="-1"
  aria-label={label}
  ontoggle={toggled}
  onkeydown={keydown}
  onfocusout={focusout}
>
  {#each items as item, i (i)}
    {#if item === '-'}
      <div class="separator" role="separator"></div>
    {:else}
      <button type="button" role="menuitem" tabindex="-1" onclick={() => choose(item)}>
        {item.text}
      </button>
    {/if}
  {/each}
</div>

<style>
  .kc-menu {
    /* At the point it opens, not the middle of the window where a popover goes */
    position: fixed;
    inset: auto;
    margin: 0;
    min-width: 12em;
    padding: 4px;
    font: inherit;
    color: var(--kc-fg);
    background: var(--kc-bg);
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
    box-shadow: 0 6px 20px rgb(0 0 0 / 0.18);
  }
  button {
    display: block;
    width: 100%;
    padding: 4px 12px;
    font: inherit;
    text-align: left;
    color: inherit;
    background: none;
    border: none;
    border-radius: var(--kc-radius);
    cursor: pointer;
  }
  button:hover,
  button:focus {
    outline: none;
    background: var(--kc-hover);
  }
  button:focus-visible {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .separator {
    height: 1px;
    margin: 4px 0;
    background: var(--kc-border);
  }
</style>
