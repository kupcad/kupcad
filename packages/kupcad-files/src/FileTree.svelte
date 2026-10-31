<!--
  @component
  A project's tree: its folders, scripts and the files they read, each under its folder, under a
  bar with its title and what can be made in it (`onnew`: a script, a folder). A folder,
  clicked, opens or closes, nothing under a closed one shown; a script, clicked, is opened (and a
  file the host opens too, `opens`: a JSON file); the open one is marked, and one with unsaved
  changes too. The arrow keys move through it as
  through any tree: up and down from row to row, right into a folder (opening it first), left
  out of it to its folder (closing an open one first). A row's menu (a right click, the menu key
  or Shift+F10) and the tree's are the host's (`onmenu`, with where to show it); F2 renames a
  row, Delete or ⌘⌫ (Ctrl+Backspace) removes it. A name being given (`editing`: a row renamed,
  an entry made in a folder) is a field in the tree, Enter giving it and Escape leaving it, what
  is wrong with it said under it (`problem`). Files dragged from the system's file manager are
  dropped in a folder (`ondropfiles`): a folder's row's own, the one a file's row is in, the
  root's elsewhere in the tree, that folder marked while they are over it. It fills its box, the
  rows scrolling under the bar.
-->
<script>
  import { draggingFiles } from './drop.js';
  import { foldersAbove, parentOf, shownEntries } from './tree.js';

  /** @import { Entry } from './tree.js' */

  /**
   * @typedef {object} Props
   * @property {Entry[]} entries
   * @property {ReadonlySet<string>} collapsed the closed folders' paths
   * @property {string | null} selected the open script's path
   * @property {ReadonlySet<string>} unsaved the paths of the scripts with unsaved changes
   * @property {(entry: Entry) => void} onopen
   * @property {(entry: Entry) => boolean} [opens] which files besides scripts it opens: by
   *   default none
   * @property {(folder: Entry, open: boolean) => void} ontoggle opens or closes a folder
   * @property {string} [root] the folder's own path: where an entry made in no folder of it goes
   * @property {Naming | null} [editing] the name being given, if one is
   * @property {string | null} [problem] what is wrong with the name given last
   * @property {(name: string) => void} [oncommit] the name is given
   * @property {() => void} [oncancel] it isn't
   * @property {(entry: Entry | null, at: Point) => void} [onmenu] a row's menu, or the tree's
   *   (null), to show at `at`: where the pointer is, or under the row for the keys
   * @property {(entry: Entry) => void} [onrename]
   * @property {(entry: Entry) => void} [ontrash] removes it
   * @property {(kind: 'script' | 'folder') => void} [onnew] makes one: the bar's buttons
   * @property {string} [title] the bar's
   * @property {{ script?: string, folder?: string }} [keys] the host's shortcuts for the bar's
   *   buttons, shown in their tooltips (`⌘N`)
   * @property {(files: File[], folder: string) => void} [ondropfiles] files from outside the
   *   page dropped on the tree, for `folder`; without it the tree takes no drop
   */

  /** A point in the window, in its pixels. @typedef {{ x: number, y: number }} Point */

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
    opens = () => false,
    ontoggle,
    root = '',
    editing = null,
    problem = null,
    oncommit,
    oncancel,
    onmenu,
    onrename,
    ontrash,
    onnew,
    title = 'Files',
    keys = {},
    ondropfiles,
  } = $props();

  const id = $props.id();

  const shown = $derived(shownEntries(entries, collapsed));
  let list = $state(/** @type {HTMLUListElement | null} */ (null));
  /** The folder files dragged over the tree would be dropped in. */
  let dropping = $state(/** @type {string | null} */ (null));

  /**
   * The folder files dropped on `target` go in: a folder's row's own, the one a file's row is in,
   * the root's elsewhere in the tree.
   * @param {EventTarget | null} target
   */
  function folderAt(target) {
    const row = target instanceof Element ? target.closest('li[data-path]') : null;
    const entry = entries.find((candidate) => candidate.path === row?.getAttribute('data-path'));
    if (!entry) return root;
    return entry.kind === 'folder' ? entry.path : parentOf(entry.path);
  }

  /** @param {DragEvent} event */
  function dragover(event) {
    if (!ondropfiles || !draggingFiles(event)) return;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy';
    dropping = folderAt(event.target);
  }

  /** Off the tree (onto the page, out of the window): nothing is dropped on it. @param {DragEvent} event */
  function dragleave(event) {
    const into = event.relatedTarget;
    if (!(
      into instanceof Node &&
      event.currentTarget instanceof Node &&
      event.currentTarget.contains(into)
    )) {
      dropping = null;
    }
  }

  /** @param {DragEvent} event */
  function drop(event) {
    if (!ondropfiles || !draggingFiles(event)) return;
    event.preventDefault();
    dropping = null;
    ondropfiles([...(event.dataTransfer?.files ?? [])], folderAt(event.target));
  }

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
      const { left, bottom } = rows[row].getBoundingClientRect();
      onmenu?.(entry, { x: left, y: bottom });
    } else if (event.key === 'ArrowDown') rows[row + 1]?.focus();
    else if (event.key === 'ArrowUp') rows[row - 1]?.focus();
    else if (event.key === 'ArrowRight' && entry.kind === 'folder') {
      if (closed) ontoggle(entry, true);
      else {
        // The first row in it that can take the focus (a data file's can't)
        const inside = shown
          .slice(at + 1)
          .find((next) => next.depth <= entry.depth || rowOf(next.path));
        if (inside && inside.depth > entry.depth) rowOf(inside.path)?.focus();
      }
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
    onmenu(entry, { x: event.clientX, y: event.clientY });
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

<!-- svelte-ignore a11y_no_static_element_interactions: a drop of files from the system's file manager, which the bar's buttons and the rows' menus offer the keys too (the host's upload) -->
<div class="kc-files" ondragover={dragover} ondragleave={dragleave} ondrop={drop}>
  <div class="bar">
    <span class="title">{title}</span>
    {#if onnew}
      <button
        type="button"
        class="action"
        aria-label="New script"
        title={keys.script ? `New script (${keys.script})` : 'New script'}
        onclick={() => onnew('script')}
      >
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M7 3.5h7l4 4v13H7z" />
          <path d="M14 3.5v4h4M12.5 11v6M9.5 14h6" />
        </svg>
      </button>
      <button
        type="button"
        class="action"
        aria-label="New folder"
        title={keys.folder ? `New folder (${keys.folder})` : 'New folder'}
        onclick={() => onnew('folder')}
      >
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M3.5 6.5h6l2 2h9v11h-17z" />
          <path d="M12 11v6M9 14h6" />
        </svg>
      </button>
    {/if}
  </div>
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions: its rows are the buttons the keys move between, and their menu is the keys' too -->
  <ul
    class="tree"
    class:dropping={dropping !== null && dropping === root}
    bind:this={list}
    onkeydown={keydown}
    oncontextmenu={(event) => menu(event, null)}
  >
    {#if editing && 'in' in editing && editing.in === root}{@render made(0)}{/if}
    {#each shown as entry (entry.path)}
      {#if editing && 'path' in editing && editing.path === entry.path}
        {@render field(entry.name, `Rename ${entry.name}`, entry.depth)}
      {:else}
        <!-- svelte-ignore a11y_no_noninteractive_element_interactions: a row's menu is its keys' too -->
        <li
          class={entry.kind}
          class:dropping={entry.kind === 'folder' && entry.path === dropping}
          data-path={entry.path}
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
          {:else if entry.kind === 'script' || opens(entry)}
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
</div>

<style>
  .kc-files {
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
  }
  /* The tree's own bar: its title, and what can be made in it, each a plain icon in the text's
     colour */
  .bar {
    flex: none;
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 3px 4px 3px 12px;
    border-bottom: 1px solid var(--kc-border);
  }
  .title {
    flex: 1;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--kc-muted);
  }
  .action {
    flex: none;
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    padding: 0;
    color: var(--kc-fg);
  }
  .action:focus-visible {
    outline: 2px solid var(--kc-focus);
    outline-offset: -2px;
  }
  .action svg {
    width: 18px;
    height: 18px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.5;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  .tree {
    flex: 1;
    min-height: 0;
    overflow: auto;
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
  /* Where files dragged over the tree would be dropped: a folder's row, or the whole tree for its
     root */
  .dropping {
    background: var(--kc-accent-subtle);
    outline: 1px dashed var(--kc-accent);
    outline-offset: -1px;
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
