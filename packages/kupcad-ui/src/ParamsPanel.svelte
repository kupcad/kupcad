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
  {#each groups as { group, parameters } (group)}
    <fieldset>
      {#if group}<legend>{group}</legend>{/if}
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
    </fieldset>
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
  /* Its parameters, a line between each (ParamField) */
  fieldset {
    display: flex;
    flex-direction: column;
    /* As wide as the panel, not as its widest control (a fieldset's own minimum) */
    min-inline-size: 0;
    margin: 0;
    padding: 0 var(--kc-gap);
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
  }
  legend {
    padding: 0 4px;
    color: var(--kc-muted);
  }
</style>
