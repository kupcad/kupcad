<!--
  @component
  The folder's tree: its folders, scripts and the files they read, each under its folder. A
  folder, clicked, opens or closes, nothing under a closed one shown; a script, clicked, is
  opened; the open one is marked, and one with unsaved changes too. The arrow keys move through
  it as through any tree: up and down from row to row, right into a folder (opening it first),
  left out of it to its folder (closing an open one first).
-->
<script>
  import { foldersAbove, shownEntries } from './folder.js';

  /** @import { Entry } from './folder.js' */

  /**
   * @typedef {object} Props
   * @property {Entry[]} entries
   * @property {ReadonlySet<string>} collapsed the closed folders' paths
   * @property {string | null} selected the open script's path
   * @property {ReadonlySet<string>} unsaved the paths of the scripts with unsaved changes
   * @property {(entry: Entry) => void} onopen
   * @property {(folder: Entry, open: boolean) => void} ontoggle opens or closes a folder
   */

  /** @type {Props} */
  let { entries, collapsed, selected, unsaved, onopen, ontoggle } = $props();

  const shown = $derived(shownEntries(entries, collapsed));
  let list = $state(/** @type {HTMLUListElement | null} */ (null));

  /** The row of the entry at `path`, when it has one to focus (data files have none). */
  const rowOf = (/** @type {string | undefined} */ path) =>
    [...(list?.querySelectorAll('button') ?? [])].find((button) => button.dataset.path === path);

  /** @param {KeyboardEvent} event */
  function keydown(event) {
    const rows = [...(list?.querySelectorAll('button') ?? [])];
    const row = rows.indexOf(/** @type {HTMLButtonElement} */ (document.activeElement));
    const at = shown.findIndex((entry) => entry.path === rows[row]?.dataset.path);
    if (at < 0) return;
    const entry = shown[at];
    const closed = entry.kind === 'folder' && collapsed.has(entry.path);
    if (event.key === 'ArrowDown') rows[row + 1]?.focus();
    else if (event.key === 'ArrowUp') rows[row - 1]?.focus();
    else if (event.key === 'ArrowRight' && entry.kind === 'folder') {
      if (closed) ontoggle(entry, true);
      else if (shown[at + 1]?.depth > entry.depth) rowOf(shown[at + 1].path)?.focus();
    } else if (event.key === 'ArrowLeft') {
      if (entry.kind === 'folder' && !closed) ontoggle(entry, false);
      else rowOf(foldersAbove(entries, entry.path).at(-1))?.focus();
    } else return;
    event.preventDefault();
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions: its rows are the buttons the keys move between -->
<ul class="tree" bind:this={list} onkeydown={keydown}>
  {#each shown as entry (entry.path)}
    <li class={entry.kind} style:padding-left="{entry.depth * 12 + 8}px">
      {#if entry.kind === 'folder'}
        {@const open = !collapsed.has(entry.path)}
        <button
          type="button"
          data-path={entry.path}
          aria-expanded={open}
          title={entry.path}
          onclick={() => ontoggle(entry, !open)}
        >
          <span class="twisty" aria-hidden="true">{open ? '▾' : '▸'}</span>{entry.name}
        </button>
      {:else if entry.kind === 'script'}
        <span class="twisty" aria-hidden="true"></span>
        <button
          type="button"
          data-path={entry.path}
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
        <span class="twisty" aria-hidden="true"></span>
        <span class="name" title={entry.path}>{entry.name}</span>
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
  /* The folders' arrow, and its room in the other rows, so names at one depth line up */
  .twisty {
    flex: none;
    display: inline-block;
    width: 12px;
    text-align: center;
  }
  .name {
    padding: 2px 4px;
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
  /* A folder's arrow is inside its button, in the room the padding takes in the others */
  .folder button {
    padding-left: 0;
    color: inherit;
  }
  .folder .twisty {
    margin-right: 4px;
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
