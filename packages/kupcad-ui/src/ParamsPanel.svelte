<!--
  @component
  The parameters' controls, from the schema a frame (or `kupcad doc`) gives: grouped by their
  `group:`, each showing the value set in the panel, else the one the run took. `overrides` is
  what the panel sets (bindable), each change (and revert) given to `onchange` as plain values,
  which a host sends to the core (to a worker, a webview's host: a list kept in state is a proxy
  that a message can't copy); a value refused by the run is shown on its control. A bar at the
  top, held there as the panel scrolls, says how many values are set; while any is, its Reset
  all reverts them all at once, the panel's refusals with them. The button keeps its place when
  there is nothing to reset, so nothing under the bar moves as a first value is set or the last
  reverted.
  A value set back to the parameter's own (the one it showed before the panel set it: the run's,
  the script's or a host's preset's) is a revert, not a value set.
-->
<script>
  import ParamField from './ParamField.svelte';
  import {
    groupsOf,
    isOverridden,
    sameValue,
    shownValue,
    withOverride,
    withoutOverride,
  } from './params.js';
  import { plainValues } from './values.svelte.js';

  /** @import { Failure, ParamSpec, ParamValue, ParamValues, UiSchema } from '@kupcad/protocol/types' */

  /**
   * @typedef {object} Props
   * @property {UiSchema} schema
   * @property {ParamValues} [values] the values the run took
   * @property {Failure | null} [error] the frame's error: the parameter it refused is marked,
   *   and the place in its value
   * @property {ParamValues} [overrides] the values the panel sets; bindable
   * @property {(overrides: ParamValues) => void} [onchange]
   */

  /** @type {Props} */
  let { schema, values = {}, error = null, overrides = $bindable({}), onchange } = $props();

  const groups = $derived(groupsOf(schema.parameters));
  const set = $derived(Object.keys(overrides).length);
  /** How many times all were reset: the fields are made again, and their refusals go. */
  let resets = $state(0);

  /**
   * Each parameter's own value, which setting it to again reverts it: the one it showed before
   * the panel first set it. Taken again from a later run, not from `stale`, the run of the
   * panel's value just reverted, until the next comes.
   * @type {Map<string, { value: ParamValue | null, stale: ParamValues | null }>}
   */
  const own = new Map();

  /** @param {ParamValues} next */
  function change(next) {
    overrides = next;
    onchange?.(plainValues(next));
  }

  /**
   * The panel sets `spec` to `value`; to its own value, it sets it no more.
   * @param {ParamSpec} spec
   * @param {ParamValue} value
   */
  function setParam(spec, value) {
    if (!isOverridden(overrides, spec.name) && own.get(spec.name)?.stale !== values) {
      own.set(spec.name, { value: shownValue(spec, overrides, values), stale: null });
    }
    if (sameValue(value, own.get(spec.name)?.value)) revert(spec.name);
    else change(withOverride(overrides, spec.name, value));
  }

  /** @param {string} name */
  function revert(name) {
    const kept = own.get(name);
    if (kept) own.set(name, { ...kept, stale: values });
    change(withoutOverride(overrides, name));
  }

  function resetAll() {
    for (const [name, kept] of own) {
      if (isOverridden(overrides, name)) own.set(name, { ...kept, stale: values });
    }
    resets += 1;
    change({});
  }
</script>

<form class="kc-params" onsubmit={(event) => event.preventDefault()}>
  <div class="bar">
    <span class="set">{set === 0 ? "The script's values" : `${set} changed`}</span>
    <!-- Unseen, not gone, while nothing is set: its room kept, out of reach of the keys -->
    <button
      type="button"
      class="kc-control reset"
      title="Every parameter back to the script's value"
      style:visibility={set > 0 ? null : 'hidden'}
      onclick={resetAll}
    >
      Reset all
    </button>
  </div>
  {#if schema.meta.title}<h2>{schema.meta.title}</h2>{/if}
  {#if schema.meta.description}<p class="description">{schema.meta.description}</p>{/if}
  {#snippet fields(/** @type {import('@kupcad/protocol/types').ParamSpec[]} */ parameters)}
    <!-- Made again on a reset, not the groups around them: a folded one stays so -->
    {#key resets}
      {#each parameters as spec (spec.name)}
        <ParamField
          {spec}
          value={shownValue(spec, overrides, values)}
          overridden={isOverridden(overrides, spec.name)}
          refused={error?.param === spec.name ? error.message : null}
          refusedAt={error?.param === spec.name ? error.path : []}
          onset={(value) => setParam(spec, value)}
          onrevert={() => revert(spec.name)}
        />
      {/each}
    {/key}
  {/snippet}
  {#each groups as { group, parameters } (group)}
    {#if group}
      <!-- A group under its title, folded away with it -->
      <details class="group" open>
        <summary>{group}</summary>
        <div class="fields" role="group" aria-label={group}>{@render fields(parameters)}</div>
      </details>
    {:else}
      <div class="fields">{@render fields(parameters)}</div>
    {/if}
  {:else}
    <p class="empty">This script has no parameters.</p>
  {/each}
</form>

<style>
  .kc-params {
    display: flex;
    flex-direction: column;
    gap: var(--kc-gap);
    font-family: var(--kc-font);
    font-size: var(--kc-font-size);
    color: var(--kc-fg);
    background: var(--kc-bg);
  }
  h2 {
    margin: 0;
    font-size: 1.1em;
  }
  .description,
  .empty {
    margin: 0;
    color: var(--kc-muted);
  }
  /* Always there, a line under it, held at the top of the column as it scrolls: its own space
     above it, so what scrolls under it shows nowhere above it (a host's column gives none) */
  .bar {
    position: sticky;
    top: 0;
    z-index: 1;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--kc-gap);
    padding: var(--kc-gap) 0 6px;
    background: var(--kc-bg);
    border-bottom: 1px solid var(--kc-border);
  }
  .set {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--kc-muted);
  }
  .reset {
    flex: none;
  }
  /* Parameters, a line between each (ParamField) */
  .fields {
    display: flex;
    flex-direction: column;
    min-width: 0;
    padding: 0 var(--kc-gap);
  }
  /* A group stands apart from its controls: a section with a header of its own */
  .group {
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
    overflow: hidden;
  }
  summary {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px var(--kc-gap);
    font-size: 0.85em;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--kc-section-fg);
    background: var(--kc-section-bg);
    cursor: pointer;
    list-style: none;
  }
  summary::-webkit-details-marker {
    display: none;
  }
  summary::before {
    content: '▾';
  }
  .group:not([open]) summary::before {
    content: '▸';
  }
  .group[open] summary {
    border-bottom: 1px solid var(--kc-border);
  }
</style>
