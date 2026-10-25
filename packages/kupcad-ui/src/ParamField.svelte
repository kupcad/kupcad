<!--
  @component
  One parameter, in rows: its title (its name where it has none) with a revert while the panel
  overrides it, its description, its control as its schema says (params.js's controlOf) with its
  unit, and why its value was refused: by the panel's own check, or by the run (`refused`, the
  frame's error naming it).
-->
<script>
  import { controlOf, stepOf, validate } from './params.js';

  /** @import { ParamSpec } from '@kupcad/protocol/types' */
  /** @import { Value } from './params.js' */

  /**
   * @typedef {object} Props
   * @property {ParamSpec} spec
   * @property {Value | null} value what the control shows
   * @property {boolean} overridden the panel sets it, in place of the script's value
   * @property {string | null} refused why the run refused its value
   * @property {(value: Value) => void} onset a value the script takes was given
   * @property {() => void} onrevert
   */

  /** @type {Props} */
  let { spec, value, overridden, refused, onset, onrevert } = $props();

  const id = $props.id();
  const errorId = `${id}-error`;
  const descriptionId = `${id}-description`;
  const control = $derived(controlOf(spec));
  /** What the control is labelled by: its title, else its name. */
  const label = $derived(spec.title || spec.name);
  /**
   * Why the value last given isn't one the script takes, and the value shown then: another
   * (a revert, the next run's) takes it away.
   */
  let refusal = $state(/** @type {{ why: string, shown: Value | null } | null} */ (null));
  const invalid = $derived(refusal?.shown === value ? refusal.why : null);
  const message = $derived(invalid ?? refused);
  /** What ties the control to its description and to its message, while there is one. */
  const described = $derived({
    'aria-invalid': message === null ? undefined : true,
    'aria-describedby':
      [spec.description && descriptionId, message !== null && errorId].filter(Boolean).join(' ') ||
      undefined,
  });
  const chosen = $derived(
    (spec.validate.in ?? []).findIndex((choice) => String(choice) === String(value)),
  );

  /** @param {Value} input */
  function commit(input) {
    const result = validate(spec, input);
    if ('error' in result) {
      refusal = { why: result.error, shown: value };
      return;
    }
    refusal = null;
    onset(result.value);
  }

  function revert() {
    refusal = null;
    onrevert();
  }

  /** @param {Event} event */
  const fromInput = (event) => commit(/** @type {HTMLInputElement} */ (event.currentTarget).value);
</script>

{#snippet numberInput()}
  <input
    {id}
    class="kc-control"
    type="number"
    min={spec.validate.min}
    max={spec.validate.max}
    step={stepOf(spec)}
    value={value ?? ''}
    onchange={fromInput}
    {...described}
  />
{/snippet}

<div class="field" class:overridden>
  <div class="head">
    <!-- The name the script reads it by, where the title hides it -->
    <label for={id} title={spec.title ? spec.name : undefined}>{label}</label>
    {#if overridden}
      <button type="button" class="revert" aria-label="Revert {label}" onclick={revert}> ↺ </button>
    {/if}
  </div>
  {#if spec.description}
    <p class="description" id={descriptionId}>{spec.description}</p>
  {/if}
  <div class="control">
    {#if control === 'slider'}
      <input
        type="range"
        min={spec.validate.min}
        max={spec.validate.max}
        step={stepOf(spec)}
        value={value ?? ''}
        aria-label="{label} slider"
        onchange={fromInput}
        {...described}
      />
      {@render numberInput()}
    {:else if control === 'number'}
      {@render numberInput()}
    {:else if control === 'select'}
      <select
        {id}
        class="kc-control"
        onchange={(event) => {
          const index = Number(event.currentTarget.value);
          commit(/** @type {Value[]} */ (spec.validate.in)[index]);
        }}
        {...described}
      >
        <!-- No choice yet (the script computes its default, and no run took one) -->
        {#if chosen === -1}<option value="" selected disabled></option>{/if}
        {#each spec.validate.in ?? [] as choice, index (index)}
          <option value={index} selected={index === chosen}>{choice}</option>
        {/each}
      </select>
    {:else if control === 'toggle'}
      <input
        {id}
        type="checkbox"
        checked={value === true}
        onchange={(event) => commit(event.currentTarget.checked)}
        {...described}
      />
    {:else}
      <input
        {id}
        class="kc-control"
        type="text"
        value={value ?? ''}
        onchange={fromInput}
        {...described}
      />
    {/if}
    {#if spec.unit}<span class="unit">{spec.unit}</span>{/if}
  </div>
  {#if message !== null}
    <p class="error" id={errorId} role="alert">{message}</p>
  {/if}
</div>

<style>
  .field {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 6px 0;
  }
  /* A line between one parameter and the next */
  .field + .field {
    border-top: 1px solid var(--kc-border);
  }
  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 4px;
  }
  label {
    color: var(--kc-muted);
    overflow-wrap: anywhere;
  }
  .description {
    margin: 0;
    color: var(--kc-muted);
    font-size: 0.92em;
  }
  .overridden label {
    color: var(--kc-fg);
    font-weight: 600;
  }
  .control {
    display: flex;
    align-items: center;
    gap: 4px;
    min-width: 0;
  }
  /* As wide as the row leaves it: its own width (a browser's 129px) would widen the panel */
  input[type='range'] {
    flex: 1;
    width: 0;
    min-width: 4em;
  }
  .kc-control {
    min-width: 0;
    width: 5em;
    padding: 2px 4px;
  }
  input[type='text'] {
    flex: 1;
  }
  .unit {
    color: var(--kc-muted);
  }
  .revert {
    font: inherit;
    color: var(--kc-accent);
    background: none;
    border: none;
    cursor: pointer;
    padding: 0 2px;
  }
  .error {
    margin: 0;
    color: var(--kc-error);
  }
</style>
