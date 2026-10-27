<!--
  @component
  The folder's tree: its folders, scripts and the files they read, each under its folder. A
  script, clicked, is opened; the open one is marked, and one with unsaved changes too.
-->
<script>
  /** @import { Entry } from './folder.js' */

  /**
   * @typedef {object} Props
   * @property {Entry[]} entries
   * @property {string | null} selected the open script's path
   * @property {ReadonlySet<string>} unsaved the paths of the scripts with unsaved changes
   * @property {(entry: Entry) => void} onopen
   */

  /** @type {Props} */
  let { entries, selected, unsaved, onopen } = $props();
</script>

<ul class="tree">
  {#each entries as entry (entry.path)}
    <li class={entry.kind} style:padding-left="{entry.depth * 12 + 8}px">
      {#if entry.kind === 'script'}
        <button
          type="button"
          class:selected={entry.path === selected}
          aria-current={entry.path === selected ? 'true' : undefined}
          aria-label={unsaved.has(entry.path) ? `${entry.name}, unsaved` : entry.name}
          title={entry.path}
          onclick={() => onopen(entry)}
        >
          {entry.name}{#if unsaved.has(entry.path)}<span class="unsaved" aria-hidden="true">●</span
            >{/if}
        </button>
      {:else}
        <span title={entry.path}>{entry.name}</span>
      {/if}
    </li>
  {:else}
    <li class="empty">No scripts here.</li>
  {/each}
</ul>

<style>
  .tree {
    margin: 0;
    padding: 4px 0;
    list-style: none;
  }
  li {
    display: flex;
    min-height: 22px;
    align-items: center;
    padding-right: 8px;
    white-space: nowrap;
  }
  .folder {
    color: var(--kc-muted);
    font-weight: 600;
  }
  .data,
  .empty {
    color: var(--kc-muted);
  }
  .empty {
    padding-left: 8px;
  }
  button {
    flex: 1;
    min-width: 0;
    padding: 2px 4px;
    overflow: hidden;
    text-overflow: ellipsis;
    text-align: left;
    font: inherit;
    color: var(--kc-fg);
    background: none;
    border: none;
    border-radius: var(--kc-radius);
    cursor: pointer;
  }
  button:hover {
    background: var(--kc-hover, rgba(127, 127, 127, 0.12));
  }
  button.selected {
    color: var(--kc-accent-fg);
    background: var(--kc-accent);
  }
  .unsaved {
    margin-left: 4px;
  }
</style>
