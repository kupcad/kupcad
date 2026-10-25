<!--
  @component
  The console under the model, as OpenSCAD's: each run of the script shown and the host's log
  (console.js's lines), the newest at the bottom, followed as they come unless the person has
  scrolled up to read. A line that names a place in the script, clicked, shows it there. It is
  cleared with its button, and folded away to its bar with its title.
-->
<script>
  /** @import { ConsoleLine } from './console.js' */

  /**
   * @typedef {object} Props
   * @property {readonly ConsoleLine[]} lines
   * @property {boolean} [open] whether its lines show; bindable
   * @property {(line: ConsoleLine) => void} [onreveal] a line that names a place, clicked
   * @property {() => void} [onclear]
   */

  /** @type {Props} */
  let { lines, open = $bindable(true), onreveal, onclear } = $props();

  /** @type {HTMLOListElement | undefined} */
  let list = $state();
  /** Whether the newest line was in view before the next came: then they are followed. */
  let following = true;

  $effect.pre(() => {
    void lines.length;
    if (list) following = list.scrollTop + list.clientHeight >= list.scrollHeight - 1;
  });
  $effect(() => {
    void lines.length;
    if (list && following) list.scrollTop = list.scrollHeight;
  });
</script>

<section class="kc-console" aria-label="Console">
  <div class="bar">
    <button type="button" class="title" aria-expanded={open} onclick={() => (open = !open)}>
      Console
    </button>
    <button
      type="button"
      class="kc-control"
      disabled={lines.length === 0}
      onclick={() => onclear?.()}
    >
      Clear
    </button>
  </div>
  {#if open}
    <ol class="lines" role="log" bind:this={list}>
      {#each lines as line, index (index)}
        <li class={line.kind}>
          {#if line.line !== null && onreveal}
            <button type="button" class="place" onclick={() => onreveal(line)}>
              {line.text} <span class="at">line {line.line}</span>
            </button>
          {:else}
            {line.text}
          {/if}
        </li>
      {/each}
    </ol>
  {/if}
</section>

<style>
  .kc-console {
    display: flex;
    flex-direction: column;
    border-top: 1px solid var(--kc-border);
    background: var(--kc-bg);
    font-family: var(--kc-font);
    font-size: var(--kc-font-size);
    color: var(--kc-fg);
  }
  .bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 2px var(--kc-gap);
  }
  .title {
    padding: 2px 0;
    font: inherit;
    color: var(--kc-muted);
    background: none;
    border: none;
    cursor: pointer;
  }
  .title::before {
    content: '▾ ';
  }
  .title[aria-expanded='false']::before {
    content: '▸ ';
  }
  /* As tall as the person drags it, a few lines to start */
  .lines {
    height: 9em;
    min-height: 3em;
    margin: 0;
    padding: 0 var(--kc-gap) 4px;
    overflow: auto;
    resize: vertical;
    list-style: none;
    font-family: var(--kc-code-font, ui-monospace, Menlo, Consolas, monospace);
    font-size: 0.92em;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .run {
    margin-top: 4px;
    color: var(--kc-muted);
  }
  .log {
    color: var(--kc-muted);
  }
  .warning {
    color: var(--kc-warning);
  }
  .error {
    color: var(--kc-error);
  }
  .place {
    padding: 0;
    font: inherit;
    color: inherit;
    text-align: left;
    background: none;
    border: none;
    cursor: pointer;
  }
  .place:hover .at {
    text-decoration: underline;
  }
  .at {
    color: var(--kc-muted);
  }
</style>
