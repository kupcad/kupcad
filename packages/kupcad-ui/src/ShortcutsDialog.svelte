<!--
  @component
  The keys and the pointer's moves a person can't see on the screen, by group (a host's own, the
  viewer's: `VIEWER_SHORTCUTS`), in a modal dialog while `open` (bindable). Escape or its close
  button closes it, and the focus goes back to what had it when it opened.
-->
<script>
  /** @import { ShortcutGroup } from './shortcuts.js' */

  /**
   * @typedef {object} Props
   * @property {readonly ShortcutGroup[]} groups
   * @property {boolean} [open] whether it shows; bindable
   */

  /** @type {Props} */
  let { groups, open = $bindable(false) } = $props();

  const id = $props.id();
  /** @type {HTMLDialogElement} */
  let dialog;
  /** What had the focus when it opened, given it back when it closes. */
  let before = /** @type {HTMLElement | null} */ (null);

  $effect(() => {
    if (open && !dialog.open) {
      const active = document.activeElement;
      before = active instanceof HTMLElement ? active : null;
      dialog.showModal();
    } else if (!open && dialog.open) {
      dialog.close();
    }
  });

  /** It closed: by Escape, its button, or `open` set false. */
  function closed() {
    open = false;
    before?.focus();
    before = null;
  }

  /** @param {KeyboardEvent} event */
  function keydown(event) {
    // A browser's modal dialog closes on Escape by itself; a webview's may not
    if (event.key !== 'Escape') return;
    event.preventDefault();
    dialog.close();
  }
</script>

<dialog
  class="kc-shortcuts"
  aria-labelledby="{id}-title"
  bind:this={dialog}
  onclose={closed}
  onkeydown={keydown}
>
  <header>
    <h2 id="{id}-title">Keyboard shortcuts</h2>
    <button type="button" class="close" aria-label="Close" onclick={() => dialog.close()}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
    </button>
  </header>
  {#each groups as group, index (index)}
    <section aria-labelledby="{id}-group-{index}">
      <h3 id="{id}-group-{index}">{group.title}</h3>
      {#if group.note}<p class="note">{group.note}</p>{/if}
      <dl>
        {#each group.keys as [keys, what], at (at)}
          <div class="row">
            <dt><kbd>{keys}</kbd></dt>
            <dd>{what}</dd>
          </div>
        {/each}
      </dl>
    </section>
  {/each}
</dialog>

<style>
  /* In the middle of the window by its own margin, not the browser's default one, which a page's
     reset (Tailwind's) takes away */
  .kc-shortcuts {
    width: min(32em, calc(100vw - 32px));
    max-height: calc(100vh - 64px);
    margin: auto;
    padding: 16px 20px;
    font-family: var(--kc-font);
    font-size: var(--kc-font-size);
    color: var(--kc-fg);
    background: var(--kc-bg);
    border: 1px solid var(--kc-border);
    border-radius: calc(var(--kc-radius) * 2);
  }
  .kc-shortcuts::backdrop {
    background: rgb(0 0 0 / 0.35);
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 8px;
  }
  h2 {
    margin: 0;
    font-size: 1.25em;
  }
  h3 {
    margin: 12px 0 4px;
    font-size: 1em;
  }
  .close {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
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
    width: 16px;
    height: 16px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.75;
    stroke-linecap: round;
  }
  .note {
    margin: 0 0 4px;
    color: var(--kc-muted);
  }
  /* The group's keys in a column as wide as its widest, what each does beside it: a row is
     its two cells, a line under each */
  dl {
    display: grid;
    grid-template-columns: max-content 1fr;
    margin: 0;
  }
  .row {
    display: contents;
  }
  dt,
  dd {
    margin: 0;
    padding: 3px 0;
    border-bottom: 1px solid var(--kc-border);
  }
  dt {
    padding-right: 16px;
  }
  kbd {
    font-family: var(--kc-code-font, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);
    font-size: 0.92em;
    padding: 1px 5px;
    color: var(--kc-section-fg);
    background: var(--kc-section-bg);
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
    white-space: nowrap;
  }
</style>
