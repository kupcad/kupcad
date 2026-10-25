<!--
  @component
  One parameter, in rows: its title (its name where it has none) with a revert while the panel
  overrides it, its description, its control as its schema says (params.js's controlOf) with its
  unit, and why its value was refused: by the panel's own check, or by the run (`refused`, the
  frame's error naming it). An array's control is a list of its elements' controls (each as
  `elementSpec` says), each with a remove, and an add.
-->
<script>
  import { controlOf, elementSpec, newElement, sameValue, stepOf, validate } from './params.js';

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
  const labelId = `${id}-label`;
  const control = $derived(controlOf(spec));
  /** An array's elements, as its list shows them (none while it has no value). */
  const items = $derived(control === 'list' && Array.isArray(value) ? value : []);
  const element = $derived(control === 'list' ? elementSpec(spec) : spec);
  /** What the control is labelled by: its title, else its name. */
  const label = $derived(spec.title || spec.name);
  /**
   * Why the value last given isn't one the script takes, and the value shown then: another
   * (a revert, the next run's) takes it away.
   */
  let refusal = $state(/** @type {{ why: string, shown: Value | null } | null} */ (null));
  // By what it holds: the array a state keeps is a copy, never the one shown
  const invalid = $derived(refusal && sameValue(refusal.shown, value) ? refusal.why : null);
  const message = $derived(invalid ?? refused);
  /** What ties the control to its description and to its message, while there is one. */
  const described = $derived({
    'aria-invalid': message === null ? undefined : true,
    'aria-describedby':
      [spec.description && descriptionId, message !== null && errorId].filter(Boolean).join(' ') ||
      undefined,
  });

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

  /**
   * The list with element `index` given `input` (the list checks it, each element as its kind).
   * @param {number} index
   * @param {Value} input
   */
  function commitElement(index, input) {
    commit(items.map((item, at) => (at === index ? input : item)));
  }

  /** @param {Event} event */
  const inputOf = (event) => /** @type {HTMLInputElement} */ (event.currentTarget).value;
</script>

<!--
  The control of a value of `of` (the parameter, or an element of its list), showing `shown`,
  giving `oncommit` what is put in it. `controlId` ties the parameter's label to it; an element's
  control is labelled by `name` instead.
-->
{#snippet editor(
  /** @type {ParamSpec} */ of,
  /** @type {Value | null} */ shown,
  /** @type {(input: Value) => void} */ oncommit,
  /** @type {{ id?: string, 'aria-label'?: string }} */ named,
  /** @type {boolean} */ nested,
)}
  {@const kind = controlOf(of, nested)}
  {@const chosen = (of.validate.in ?? []).findIndex((choice) => String(choice) === String(shown))}
  {#if kind === 'slider'}
    <input
      type="range"
      min={of.validate.min}
      max={of.validate.max}
      step={stepOf(of)}
      value={shown ?? ''}
      aria-label="{named['aria-label'] ?? label} slider"
      onchange={(event) => oncommit(inputOf(event))}
      {...described}
    />
  {/if}
  {#if kind === 'slider' || kind === 'number'}
    <input
      {...named}
      class="kc-control"
      type="number"
      min={of.validate.min}
      max={of.validate.max}
      step={stepOf(of)}
      value={shown ?? ''}
      onchange={(event) => oncommit(inputOf(event))}
      {...described}
    />
  {:else if kind === 'select'}
    <select
      {...named}
      class="kc-control"
      onchange={(event) => {
        const index = Number(event.currentTarget.value);
        oncommit(/** @type {Value[]} */ (of.validate.in)[index]);
      }}
      {...described}
    >
      <!-- No choice yet (the script computes its default, and no run took one) -->
      {#if chosen === -1}<option value="" selected disabled></option>{/if}
      {#each of.validate.in ?? [] as choice, index (index)}
        <option value={index} selected={index === chosen}>{choice}</option>
      {/each}
    </select>
  {:else if kind === 'toggle'}
    <input
      {...named}
      type="checkbox"
      checked={shown === true}
      onchange={(event) => oncommit(event.currentTarget.checked)}
      {...described}
    />
  {:else}
    <!-- Text, or an array in an array as its JSON -->
    <input
      {...named}
      class="kc-control"
      type="text"
      value={kind === 'json' ? JSON.stringify(shown ?? []) : (shown ?? '')}
      onchange={(event) => oncommit(inputOf(event))}
      {...described}
    />
  {/if}
{/snippet}

<div class="field" class:overridden>
  <div class="head">
    <!-- The name the script reads it by, where the title hides it -->
    <label
      id={labelId}
      for={control === 'list' ? undefined : id}
      title={spec.title ? spec.name : undefined}>{label}</label
    >
    {#if overridden}
      <button type="button" class="revert" aria-label="Revert {label}" onclick={revert}> ↺ </button>
    {/if}
  </div>
  {#if spec.description}
    <p class="description" id={descriptionId}>{spec.description}</p>
  {/if}
  {#if control === 'list'}
    <ol class="list" aria-labelledby={labelId}>
      {#each items as item, index (index)}
        <li class="control">
          {@render editor(
            element,
            item,
            (input) => commitElement(index, input),
            { 'aria-label': `${label} [${index}]` },
            true,
          )}
          {#if spec.unit}<span class="unit">{spec.unit}</span>{/if}
          <button
            type="button"
            class="remove"
            aria-label="Remove {label} [{index}]"
            onclick={() => commit(items.filter((_, at) => at !== index))}>−</button
          >
        </li>
      {/each}
    </ol>
    <button
      type="button"
      class="add"
      aria-label="Add to {label}"
      onclick={() => commit([...items, newElement(spec, items)])}>+ Add</button
    >
  {:else}
    <div class="control">
      {@render editor(spec, value, commit, { id }, false)}
      {#if spec.unit}<span class="unit">{spec.unit}</span>{/if}
    </div>
  {/if}
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
  .revert,
  .remove,
  .add {
    font: inherit;
    color: var(--kc-accent);
    background: none;
    border: none;
    cursor: pointer;
    padding: 0 2px;
  }
  .list {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin: 0;
    padding: 0;
    list-style: none;
  }
  .add {
    align-self: flex-start;
  }
  .error {
    margin: 0;
    color: var(--kc-error);
  }
</style>
