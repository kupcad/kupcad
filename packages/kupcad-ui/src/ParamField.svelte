<!--
  @component
  One parameter's control, as its schema says (params.js's controlOf), with its unit, a revert
  while the panel overrides it, and why its value was refused: by the panel's own check, or by
  the run (`refused`, the frame's error naming it).
-->
<script>
  import { controlOf, validate } from './params.js';

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
  const control = $derived(controlOf(spec));
  /**
   * Why the value last given isn't one the script takes, and the value shown then: another
   * (a revert, the next run's) takes it away.
   */
  let refusal = $state(/** @type {{ why: string, shown: Value | null } | null} */ (null));
  const invalid = $derived(refusal?.shown === value ? refusal.why : null);
  const message = $derived(invalid ?? refused);
  /** What ties the control to its message, while there is one. */
  const described = $derived(
    message === null ? {} : { 'aria-invalid': true, 'aria-describedby': errorId },
  );
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
    type="number"
    min={spec.validate.min}
    max={spec.validate.max}
    step={spec.step ?? 'any'}
    value={value ?? ''}
    onchange={fromInput}
    {...described}
  />
{/snippet}

<div class="field" class:overridden>
  <label for={id}>{spec.name}</label>
  <div class="control">
    {#if control === 'slider'}
      <input
        type="range"
        min={spec.validate.min}
        max={spec.validate.max}
        step={spec.step ?? 'any'}
        value={value ?? ''}
        aria-label="{spec.name} slider"
        onchange={fromInput}
        {...described}
      />
      {@render numberInput()}
    {:else if control === 'number'}
      {@render numberInput()}
    {:else if control === 'select'}
      <select
        {id}
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
      <input {id} type="text" value={value ?? ''} onchange={fromInput} {...described} />
    {/if}
    {#if spec.unit}<span class="unit">{spec.unit}</span>{/if}
    {#if overridden}
      <button type="button" class="revert" aria-label="Revert {spec.name}" onclick={revert}>
        ↺
      </button>
    {/if}
  </div>
  {#if message !== null}
    <p class="error" id={errorId} role="alert">{message}</p>
  {/if}
</div>

<style>
  .field {
    display: grid;
    grid-template-columns: minmax(6em, max-content) 1fr;
    align-items: center;
    gap: 2px var(--kc-gap);
  }
  label {
    color: var(--kc-muted);
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
  input[type='range'] {
    flex: 1;
    min-width: 4em;
  }
  input:not([type='checkbox']):not([type='range']),
  select {
    min-width: 0;
    width: 5em;
    font: inherit;
    color: var(--kc-fg);
    background: var(--kc-input-bg);
    border: 1px solid var(--kc-border);
    border-radius: var(--kc-radius);
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
    grid-column: 2;
    margin: 0;
    color: var(--kc-error);
  }
</style>
