<!--
  @component
  One parameter, in rows: its title (its name where it has none) with a revert while the panel
  overrides it, its description, its control as its rules say (params.js's controlOf) with its
  unit, and why its value was refused: by the panel's own check, or by the run (`refused`, the
  frame's error naming it, and `refusedAt`, where in its value), the control there marked. A
  tuple's places and a Map's fields are controls side by side, each labelled on top; a list is
  its elements, each a control (or a block of them) with a remove, and an add, as its
  `min_items` and `max_items` allow.
-->
<script>
  import {
    canAdd,
    canRemove,
    controlOf,
    newElement,
    partAt,
    partsOf,
    sameValue,
    stepOf,
    validate,
    withPart,
  } from './params.js';

  /** @import { ParamSpec, PathStep, Rule } from '@kupcad/protocol/types' */
  /** @import { Value } from './params.js' */

  /**
   * @typedef {object} Props
   * @property {ParamSpec} spec
   * @property {Value | null} value what the control shows
   * @property {boolean} overridden the panel sets it, in place of the script's value
   * @property {string | null} refused why the run refused its value
   * @property {PathStep[]} [refusedAt] where in its value the run refused it (all of it: empty)
   * @property {(value: Value) => void} onset a value the script takes was given
   * @property {() => void} onrevert
   */

  /** @type {Props} */
  let { spec, value, overridden, refused, refusedAt = [], onset, onrevert } = $props();

  const id = $props.id();
  const errorId = `${id}-error`;
  const descriptionId = `${id}-description`;
  const labelId = `${id}-label`;
  const control = $derived(controlOf(spec));
  /** A list's elements, as it shows them (none while it has no value). */
  const items = $derived(control === 'list' && Array.isArray(value) ? value : []);
  /** A list's element's rule. */
  const element = $derived(/** @type {Rule} */ (spec.items ?? spec));
  /** Whether a list's elements are blocks of controls: tuples, or Maps. */
  const blocks = $derived(
    control === 'list' && (element.type === 'array' || element.type === 'map'),
  );
  /** What the control is labelled by: its title, else its name. */
  const label = $derived(spec.title || spec.name);
  /**
   * Why the value last given isn't one the script takes, where in it, and the value shown then:
   * another (a revert, the next run's) takes it away.
   */
  let refusal = $state(
    /** @type {{ why: string, path: PathStep[], shown: Value | null } | null} */ (null),
  );
  // By what it holds: the array a state keeps is a copy, never the one shown
  const invalid = $derived(refusal && sameValue(refusal.shown, value) ? refusal : null);
  const message = $derived(invalid?.why ?? refused);
  /** Where in the value the message is about: the panel's refusal's place, else the run's. */
  const wrongAt = $derived(invalid ? invalid.path : refused !== null ? refusedAt : null);

  /**
   * What ties the control at `path` to the description and the message, and marks it while the
   * message is about it.
   * @param {PathStep[]} path
   */
  function described(path) {
    const wrong = wrongAt !== null && sameValue(wrongAt, path);
    return {
      'aria-invalid': wrong ? true : undefined,
      'aria-describedby':
        [spec.description && descriptionId, message !== null && errorId]
          .filter(Boolean)
          .join(' ') || undefined,
    };
  }

  /** @param {Value} input the whole value */
  function commit(input) {
    const result = validate(spec, input);
    if ('error' in result) {
      refusal = { why: result.error, path: result.path, shown: value };
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
  const inputOf = (event) => /** @type {HTMLInputElement} */ (event.currentTarget).value;
</script>

<!--
  The control of a scalar of `rule` (the parameter, or a part of its value at `path`), showing
  `shown`; `named` ties it to its label (an id) or names it (an aria-label).
-->
{#snippet scalar(
  /** @type {Rule} */ rule,
  /** @type {Value | null} */ shown,
  /** @type {PathStep[]} */ path,
  /** @type {{ id?: string, 'aria-label'?: string }} */ named,
)}
  {@const kind = controlOf(rule)}
  {@const chosen = (rule.in ?? []).findIndex((choice) => String(choice) === String(shown))}
  {@const give = (/** @type {Value} */ input) => commit(withPart(value, path, input))}
  {#if kind === 'slider'}
    <input
      type="range"
      min={rule.min}
      max={rule.max}
      step={stepOf(rule)}
      value={shown ?? ''}
      aria-label="{named['aria-label'] ?? label} slider"
      onchange={(event) => give(inputOf(event))}
      {...described(path)}
    />
  {/if}
  {#if kind === 'slider' || kind === 'number'}
    <input
      {...named}
      class="kc-control"
      type="number"
      min={rule.min}
      max={rule.max}
      step={stepOf(rule)}
      value={shown ?? ''}
      onchange={(event) => give(inputOf(event))}
      {...described(path)}
    />
  {:else if kind === 'select'}
    <select
      {...named}
      class="kc-control"
      onchange={(event) =>
        give(/** @type {Value[]} */ (rule.in)[Number(event.currentTarget.value)])}
      {...described(path)}
    >
      <!-- No choice yet (it has no default, or the script computes it, and no run took one) -->
      {#if chosen === -1}<option value="" selected disabled></option>{/if}
      {#each rule.in ?? [] as choice, index (index)}
        <option value={index} selected={index === chosen}>{choice}</option>
      {/each}
    </select>
  {:else if kind === 'toggle'}
    <input
      {...named}
      type="checkbox"
      checked={shown === true}
      onchange={(event) => give(event.currentTarget.checked)}
      {...described(path)}
    />
  {:else}
    <input
      {...named}
      class="kc-control"
      type="text"
      value={shown ?? ''}
      onchange={(event) => give(inputOf(event))}
      {...described(path)}
    />
  {/if}
  {#if rule.unit}<span class="unit">{rule.unit}</span>{/if}
{/snippet}

<!-- A tuple's places, or a Map's fields, of the value at `path`: side by side, labelled on top -->
{#snippet parts(
  /** @type {Rule} */ rule,
  /** @type {Value | null} */ shown,
  /** @type {PathStep[]} */ path,
)}
  <div class="parts">
    {#each partsOf(rule) as part (part.step)}
      {@const at = [...path, part.step]}
      <!-- Of a separator the field's own ids don't have: a field may be named `label` -->
      {@const partId = `${id}/${at.join('/')}`}
      <div class="part">
        <label for={partId}>{part.label}</label>
        <div class="control">
          {@render scalar(part.rule, partAt(shown, [part.step]), at, { id: partId })}
        </div>
      </div>
    {/each}
  </div>
{/snippet}

<div class="field" class:overridden>
  <div class="head">
    <!-- The name the script reads it by, where the title hides it -->
    <label
      id={labelId}
      for={control === 'list' || control === 'tuple' || control === 'record' ? undefined : id}
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
        <li class={blocks ? 'block' : 'control'}>
          {#if blocks}
            <div class="block-head">
              <span class="index">[{index}]</span>
              {@render remove(index)}
            </div>
            <div role="group" aria-label="{label} [{index}]">
              {@render parts(element, item, [index])}
            </div>
          {:else}
            {@render scalar(element, item, [index], { 'aria-label': `${label} [${index}]` })}
            {@render remove(index)}
          {/if}
        </li>
      {/each}
    </ol>
    <button
      type="button"
      class="add"
      aria-label="Add to {label}"
      disabled={!canAdd(spec, items.length)}
      onclick={() => commit([...items, newElement(spec, items)])}>+ Add</button
    >
  {:else if control === 'tuple' || control === 'record'}
    <div role="group" aria-labelledby={labelId}>
      {@render parts(spec, value, [])}
    </div>
  {:else}
    <div class="control">
      {@render scalar(spec, value, [], { id })}
    </div>
  {/if}
  {#if message !== null}
    <p class="error" id={errorId} role="alert">{message}</p>
  {/if}
</div>

{#snippet remove(/** @type {number} */ index)}
  <button
    type="button"
    class="remove"
    aria-label="Remove {label} [{index}]"
    disabled={!canRemove(spec, items.length)}
    onclick={() => commit(items.filter((_, at) => at !== index))}>−</button
  >
{/snippet}

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
  .remove:disabled,
  .add:disabled {
    color: var(--kc-muted);
    cursor: default;
  }
  /* A tuple's places, a Map's fields: side by side, wrapping where the panel is narrow */
  .parts {
    display: flex;
    flex-wrap: wrap;
    gap: 4px 8px;
  }
  .part {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  /* An element of a list of tuples or Maps */
  .block {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 4px 6px;
    border: 1px solid var(--kc-border);
    border-radius: 3px;
  }
  .block-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .index {
    color: var(--kc-muted);
  }
  .error {
    margin: 0;
    color: var(--kc-error);
  }
</style>
