<!--
  @component
  What was done to the open script elsewhere (`where`: on the disk, in another tab) under the
  person's unsaved changes, above the editor, and their choice: the other's (`onresolve('disk')`:
  for one deleted, the script goes), or theirs (`'mine'`, which the next save writes over it).
-->
<script>
  /**
   * @typedef {object} Props
   * @property {string} name the script's
   * @property {string | null} conflict the other's text, or null for the script deleted
   * @property {string} where what did it: `on disk`, `in another tab`
   * @property {(keep: 'disk' | 'mine') => void} onresolve
   */

  /** @type {Props} */
  let { name, conflict, where, onresolve } = $props();
</script>

<div class="kc-conflict" role="alert">
  {#if conflict === null}
    <span>{name} was deleted {where}. Keeping yours saves it again.</span>
    <button type="button" class="kc-control" onclick={() => onresolve('disk')}>Discard mine</button>
  {:else}
    <span>{name} changed {where}.</span>
    <button type="button" class="kc-control" onclick={() => onresolve('disk')}>Take theirs</button>
  {/if}
  <button type="button" class="kc-control" onclick={() => onresolve('mine')}>Keep mine</button>
</div>

<style>
  .kc-conflict {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--kc-gap);
    padding: 6px var(--kc-gap);
    background: var(--kc-accent-subtle);
    border-bottom: 1px solid var(--kc-accent);
  }
  span {
    flex: 1 1 12em;
  }
</style>
