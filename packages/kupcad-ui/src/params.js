// The parameter panel's logic, apart from its markup: which control a parameter gets, how the
// parameters group, which value a control shows, and whether a value given in the panel is one
// the script takes (its schema's `validate`), checked before it leaves the panel; the run is
// the final check, and a frame names a value it refused.

/** @import { ParamSpec, ParamValues } from '@kupcad/protocol/types' */

/**
 * A slider (with a number beside it) for a number between a min and a max; a number field for
 * one without; a select for a choice of listed values; a toggle for a boolean; a text field.
 * @typedef {'slider' | 'number' | 'select' | 'toggle' | 'text'} Control
 */

/** @typedef {number | string | boolean} Value */

/**
 * @param {ParamSpec} spec
 * @returns {Control}
 */
export function controlOf(spec) {
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
 * What a control gave, as the parameter's value, or why the script wouldn't take it.
 * @param {ParamSpec} spec
 * @param {Value} input
 * @returns {{ value: Value } | { error: string }}
 */
export function validate(spec, input) {
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
