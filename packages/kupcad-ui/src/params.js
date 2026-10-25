// The parameter panel's logic, apart from its markup: which control a parameter gets, how the
// parameters group, which value a control shows, and whether a value given in the panel is one
// the script takes (its schema's `validate`), checked before it leaves the panel; the run is
// the final check, and a frame names a value it refused.

import { MAX_ARRAY_DEPTH } from '@kupcad/protocol';

/** @import { ParamSpec, ParamValue, ParamValues } from '@kupcad/protocol/types' */

/**
 * A slider (with a number beside it) for a number between a min and a max; a number field for
 * one without; a select for a choice of listed values; a toggle for a boolean; a list of
 * controls, one per element, for an array; a text field of its JSON for an array in an array;
 * a text field.
 * @typedef {'slider' | 'number' | 'select' | 'toggle' | 'list' | 'json' | 'text'} Control
 */

/** @typedef {ParamValue} Value */

/** What a nested array a text field gives must look like. */
const AN_ARRAY = 'must be an array, as [10, 20]';

/**
 * @param {ParamSpec} spec
 * @param {boolean} [nested] an element of an array, whose own arrays are text
 * @returns {Control}
 */
export function controlOf(spec, nested = false) {
  if (spec.type === 'array') return nested ? 'json' : 'list';
  if (spec.validate.in) return 'select';
  if (spec.type === 'boolean') return 'toggle';
  if (spec.type === 'string') return 'text';
  return spec.validate.min !== null && spec.validate.max !== null ? 'slider' : 'number';
}

/**
 * A number control's increment: the script's `step:`, else 1 for one between a `min` and a
 * `max` (a slider moved by a hand lands on whole numbers, not on 27.41112), or, for a range
 * narrower than 1, which a step of 1 couldn't move in, the power of ten that gives it at least
 * ten positions; any value for a number with no range.
 * @param {ParamSpec} spec
 * @returns {number | 'any'}
 */
export function stepOf(spec) {
  if (spec.step !== null) return spec.step;
  const { min, max } = spec.validate;
  if (min === null || max === null || !(max > min)) return 'any';
  const range = max - min;
  return range >= 1 ? 1 : 10 ** (Math.floor(Math.log10(range)) - 1);
}

/**
 * The parameters by their `group:`, the groups in the order the script first names them: those
 * without one first, under no heading.
 * @param {ParamSpec[]} parameters
 * @returns {{ group: string | null, parameters: ParamSpec[] }[]}
 */
export function groupsOf(parameters) {
  /** @type {Map<string | null, ParamSpec[]>} */
  const groups = new Map([[null, []]]);
  for (const spec of parameters) {
    const members = groups.get(spec.group) ?? [];
    members.push(spec);
    groups.set(spec.group, members);
  }
  return [...groups]
    .filter(([, members]) => members.length > 0)
    .map(([group, members]) => ({ group, parameters: members }));
}

/**
 * The value a parameter's control shows: the one set in the panel, else the one the run took,
 * else its default (null when the script computes it and no run took one).
 * @param {ParamSpec} spec
 * @param {ParamValues} overrides
 * @param {ParamValues} values
 * @returns {Value | null}
 */
export function shownValue(spec, overrides, values) {
  return ownValue(overrides, spec.name) ?? ownValue(values, spec.name) ?? spec.default_value;
}

/**
 * Whether the panel sets the parameter `name`: by its own key, so a parameter named like an
 * Object's member (`constructor`) isn't taken for set.
 * @param {ParamValues} overrides
 * @param {string} name
 */
export const isOverridden = (overrides, name) => Object.hasOwn(overrides, name);

/**
 * The value `values` holds under `name` itself, not one an Object has (`constructor` read a
 * function).
 * @param {ParamValues} values
 * @param {string} name
 * @returns {Value | undefined}
 */
const ownValue = (values, name) => (Object.hasOwn(values, name) ? values[name] : undefined);

/**
 * Each element of an Array parameter, as a parameter of its own: of the kind its default's
 * elements share (else its choices'; else text, as the script takes an untyped value), with the
 * parameter's range (for every number in it), choices, step and unit. An element that is an
 * array keeps the default's first, which says what its own elements are.
 * @param {ParamSpec} spec an 'array' one
 * @returns {ParamSpec}
 */
export function elementSpec(spec) {
  const elements = Array.isArray(spec.default_value) ? spec.default_value : [];
  const type = sharedType(elements) ?? sharedType(spec.validate.in ?? []) ?? 'string';
  return { ...spec, type, default_value: type === 'array' ? (elements[0] ?? null) : null };
}

/**
 * The type all of `values` have; null when there are none, or they differ.
 * @param {ParamValue[]} values
 * @returns {ParamSpec['type'] | null}
 */
function sharedType(values) {
  const types = new Set(values.map(typeOfValue));
  return types.size === 1 ? /** @type {ParamSpec['type']} */ ([...types][0]) : null;
}

/** @param {ParamValue} value */
const typeOfValue = (value) => (Array.isArray(value) ? 'array' : typeof value);

/**
 * What a new element of `spec`'s array starts as: a copy of the last, else its first choice,
 * else what is blank for its kind (a number in its range).
 * @param {ParamSpec} spec an 'array' one
 * @param {readonly ParamValue[]} items
 * @returns {ParamValue}
 */
export function newElement(spec, items) {
  if (items.length > 0) return structuredClone(items[items.length - 1]);
  const element = elementSpec(spec);
  if (element.validate.in) return element.validate.in[0];
  switch (element.type) {
    case 'number': {
      // Zero, into its range
      const { min, max } = element.validate;
      return Math.min(Math.max(0, min ?? -Infinity), max ?? Infinity);
    }
    case 'boolean':
      return false;
    case 'array':
      return [];
    default:
      return '';
  }
}

/**
 * Whether `a` and `b` are one value: arrays by their elements.
 * @param {Value | null} a
 * @param {Value | null} b
 * @returns {boolean}
 */
export function sameValue(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b)) return a === b;
  return a.length === b.length && a.every((item, index) => sameValue(item, b[index]));
}

/**
 * What a control gave, as the parameter's value, or why the script wouldn't take it.
 * @param {ParamSpec} spec
 * @param {Value} input
 * @returns {{ value: Value } | { error: string }}
 */
export function validate(spec, input) {
  return validateAt(spec, input, MAX_ARRAY_DEPTH);
}

/**
 * @param {ParamSpec} spec
 * @param {Value} input
 * @param {number} depth how much deeper its arrays may nest
 * @returns {{ value: Value } | { error: string }}
 */
function validateAt(spec, input, depth) {
  if (spec.type === 'array') return validateArray(spec, input, depth);
  const choices = spec.validate.in;
  if (choices) {
    const choice = choices.find((listed) => String(listed) === String(input));
    return choice === undefined
      ? { error: `must be one of ${choices.join(', ')}` }
      : { value: choice };
  }
  if (spec.type === 'boolean') return { value: input === true || input === 'true' };
  if (spec.type === 'string') return { value: String(input) };
  const text = String(input).trim();
  const number = Number(text);
  if (text === '' || !Number.isFinite(number)) return { error: 'must be a number' };
  const { min, max } = spec.validate;
  if (min !== null && number < min) return { error: `must be at least ${min}` };
  if (max !== null && number > max) return { error: `must be at most ${max}` };
  return { value: number };
}

/**
 * An array a list gave, or a text field of its JSON: each element as `elementSpec` takes it.
 * @param {ParamSpec} spec an 'array' one
 * @param {Value} input
 * @param {number} depth
 * @returns {{ value: Value } | { error: string }}
 */
function validateArray(spec, input, depth) {
  let items = input;
  if (typeof items === 'string') {
    try {
      items = JSON.parse(items);
    } catch {
      return { error: AN_ARRAY };
    }
  }
  if (!Array.isArray(items) || depth === 0) return { error: AN_ARRAY };
  const element = elementSpec(spec);
  /** @type {ParamValue[]} */
  const read = [];
  for (const [index, item] of items.entries()) {
    const result =
      element.type === 'array' && typeof item !== 'string' && !Array.isArray(item)
        ? { error: AN_ARRAY }
        : validateAt(element, item, depth - 1);
    if ('error' in result) return { error: `[${index}] ${result.error}` };
    read.push(result.value);
  }
  return { value: read };
}

/**
 * `overrides` with `name` set to `value`.
 * @param {ParamValues} overrides
 * @param {string} name
 * @param {Value} value
 * @returns {ParamValues}
 */
export function withOverride(overrides, name, value) {
  return { ...overrides, [name]: value };
}

/**
 * `overrides` without `name`: the parameter takes the script's value again.
 * @param {ParamValues} overrides
 * @param {string} name
 * @returns {ParamValues}
 */
export function withoutOverride(overrides, name) {
  return Object.fromEntries(Object.entries(overrides).filter(([key]) => key !== name));
}
