<!--
  @component
  The parameters' controls, from the schema a frame (or `kupcad doc`) gives: grouped by their
  `group:`, each showing the value set in the panel, else the one the run took. `overrides` is
  what the panel sets (bindable), each change (and revert) given to `onchange`, which a host
  sends to the core; a value refused by the run is shown on its control.
-->
<script>
  import ParamField from './ParamField.svelte';
  import { groupsOf, isOverridden, shownValue, withOverride, withoutOverride } from './params.js';

  /** @import { Failure, ParamValues, UiSchema } from '@kupcad/protocol/types' */

  /**
   * @typedef {object} Props
   * @property {UiSchema} schema
   * @property {ParamValues} [values] the values the run took
   * @property {Failure | null} [error] the frame's error: the parameter it refused is marked
   * @property {ParamValues} [overrides] the values the panel sets; bindable
   * @property {(overrides: ParamValues) => void} [onchange]
   */

  /** @type {Props} */
  let { schema, values = {}, error = null, overrides = $bindable({}), onchange } = $props();

  const groups = $derived(groupsOf(schema.parameters));

  /** @param {ParamValues} next */
  function change(next) {
    overrides = next;
    onchange?.(next);
  }
</script>

<form class="kc-params" onsubmit={(event) => event.preventDefault()}>
  {#if schema.meta.title}<h2>{schema.meta.title}</h2>{/if}
  {#if schema.meta.description}<p class="description">{schema.meta.description}</p>{/if}
  {#snippet fields(/** @type {import('@kupcad/protocol/types').ParamSpec[]} */ parameters)}
    {#each parameters as spec (spec.name)}
      <ParamField
        {spec}
        value={shownValue(spec, overrides, values)}
        overridden={isOverridden(overrides, spec.name)}
        refused={error?.param === spec.name ? error.message : null}
        onset={(value) => change(withOverride(overrides, spec.name, value))}
        onrevert={() => change(withoutOverride(overrides, spec.name))}
      />
    {/each}
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
