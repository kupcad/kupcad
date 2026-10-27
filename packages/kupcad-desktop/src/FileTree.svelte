<!--
  @component
  The folder's tree: its folders, scripts and the files they read, each under its folder. A
  folder, clicked, opens or closes, nothing under a closed one shown; a script, clicked, is
  opened; the open one is marked, and one with unsaved changes too. The arrow keys move through
  it as through any tree: up and down from row to row, right into a folder (opening it first),
  left out of it to its folder (closing an open one first). A row's menu (a right click, the
  menu key or Shift+F10) and the tree's are the host's (`onmenu`); F2 renames a row, Delete or
  ⌘⌫ (Ctrl+Backspace) moves it to the trash. A name being given (`editing`: a row renamed, an
  entry made in a folder) is a field in the tree, Enter giving it and Escape leaving it, what is
  wrong with it said under it (`problem`).
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
   * @property {string} [root] the folder's own path: where an entry made in no folder of it goes
   * @property {Naming | null} [editing] the name being given, if one is
   * @property {string | null} [problem] what is wrong with the name given last
   * @property {(name: string) => void} [oncommit] the name is given
   * @property {() => void} [oncancel] it isn't
   * @property {(entry: Entry | null) => void} [onmenu] a row's menu, or the tree's (null)
   * @property {(entry: Entry) => void} [onrename]
   * @property {(entry: Entry) => void} [ontrash]
   */

  /**
   * A name being given: a row's new one, or a new entry's in the folder `in`.
   * @typedef {{ path: string } | { in: string, kind: 'script' | 'folder' }} Naming
   */

  /** @type {Props} */
  let {
    entries,
    collapsed,
    selected,
    unsaved,
    onopen,
    ontoggle,
    root = '',
    editing = null,
    problem = null,
    oncommit,
    oncancel,
    onmenu,
    onrename,
    ontrash,
  } = $props();

  const id = $props.id();

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
    if (event.key === 'F2') onrename?.(entry);
    else if (
      event.key === 'Delete' ||
      (event.key === 'Backspace' && (event.metaKey || event.ctrlKey))
    ) {
      ontrash?.(entry);
    } else if (event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey)) {
      onmenu?.(entry);
    } else if (event.key === 'ArrowDown') rows[row + 1]?.focus();
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

  /**
   * The menu of `entry`'s row, or of the tree itself, in place of the page's.
   * @param {MouseEvent} event
   * @param {Entry | null} entry
   */
  function menu(event, entry) {
    if (!onmenu) return;
    event.preventDefault();
    event.stopPropagation();
    onmenu(entry);
  }

  /**
   * The field a name is given in: focused once there, its name without its extension chosen.
   * @param {HTMLInputElement} input
   */
  function naming(input) {
    input.focus();
    const dot = input.value.lastIndexOf('.');
    input.setSelectionRange(0, dot > 0 ? dot : input.value.length);
  }

  /**
   * The name in the field given (Enter, or the field left), or none where it is empty or the
   * row's own. A field left with Escape gives nothing on the blur that follows; the host takes a
   * name given again while it makes one, or once there is none to give, for nothing.
   * @param {HTMLInputElement} input
   * @param {string} given what the field started with
   */
  function settle(input, given) {
    if (input.dataset.left) return;
    const name = input.value;
    if (name.trim() !== '' && name !== given) {
      oncommit?.(name);
      return;
    }
    input.dataset.left = 'true';
    oncancel?.();
  }
</script>

{#snippet field(
  /** @type {string} */ given,
  /** @type {string} */ label,
  /** @type {number} */ depth,
)}
  <li class="naming" style:padding-left="{depth * 12 + 8}px">
    <span class="twisty" aria-hidden="true"></span>
    <span class="field">
      <input
        type="text"
        class="kc-control"
        value={given}
        aria-label={label}
        aria-invalid={problem ? 'true' : undefined}
        aria-describedby={problem ? `${id}-problem` : undefined}
        spellcheck="false"
        autocomplete="off"
        {@attach naming}
        onkeydown={(event) => {
          if (event.key === 'Enter') settle(event.currentTarget, given);
          else if (event.key === 'Escape') {
            event.currentTarget.dataset.left = 'true';
            oncancel?.();
          } else return;
          event.preventDefault();
          event.stopPropagation();
        }}
        onblur={(event) => settle(event.currentTarget, given)}
      />
      {#if problem}<span class="problem" id="{id}-problem">{problem}</span>{/if}
    </span>
  </li>
{/snippet}

{#snippet made(/** @type {number} */ depth)}
  {#if editing && 'in' in editing}
    {@render field('', editing.kind === 'script' ? 'New script name' : 'New folder name', depth)}
  {/if}
{/snippet}

<!-- svelte-ignore a11y_no_noninteractive_element_interactions: its rows are the buttons the keys move between, and their menu is the keys' too -->
<ul class="tree" bind:this={list} onkeydown={keydown} oncontextmenu={(event) => menu(event, null)}>
  {#if editing && 'in' in editing && editing.in === root}{@render made(0)}{/if}
  {#each shown as entry (entry.path)}
    {#if editing && 'path' in editing && editing.path === entry.path}
      {@render field(entry.name, `Rename ${entry.name}`, entry.depth)}
    {:else}
      <!-- svelte-ignore a11y_no_noninteractive_element_interactions: a row's menu is its keys' too -->
      <li
        class={entry.kind}
        style:padding-left="{entry.depth * 12 + 8}px"
        oncontextmenu={(event) => menu(event, entry)}
      >
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
            {entry.name}{#if unsaved.has(entry.path)}<span class="unsaved" aria-hidden="true"
                >●</span
              >{/if}
          </button>
        {:else}
          <span class="twisty" aria-hidden="true"></span>
          <span class="name" title={entry.path}>{entry.name}</span>
        {/if}
      </li>
    {/if}
    {#if editing && 'in' in editing && editing.in === entry.path}{@render made(
        entry.depth + 1,
      )}{/if}
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
    background: var(--kc-hover);
  }
  /* Tinted, its text as any row's: a full accent row outshouts the editor beside it */
  button.selected {
    background: var(--kc-accent-subtle);
  }
  .unsaved {
    margin-left: 4px;
  }
  /* A name being given: the field the row's width, what is wrong with it under it */
  .field {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    padding: 1px 0;
  }
  .field input {
    width: 100%;
    box-sizing: border-box;
    padding: 1px 4px;
    font: inherit;
  }
  .problem {
    color: var(--kc-error);
    white-space: normal;
  }
</style>
