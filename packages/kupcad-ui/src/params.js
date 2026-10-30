// The parameter panel's logic, apart from its markup: which control a parameter (or a part of its
// value) gets, how the parameters group, which value a control shows, and whether a value given
// in the panel is one the script takes (its schema's rules, core/src/core/param_rules.zig's),
// checked before it leaves the panel; the run is the final check, and a frame names a value it
// refused, and where in it.

/** @import { ParamSpec, ParamValue, ParamValues, PathStep, Rule } from '@kupcad/protocol/types' */

/**
 * A slider (with a number beside it) for a number between a min and a max; a number field for
 * one without; a select for a choice of listed values; a toggle for a boolean; a text field; and
 * for a value of parts: a list (an element's control or block each, added and removed), a tuple
 * (a control per place) or a record (a control per field of a Map).
 * @typedef {'slider' | 'number' | 'select' | 'toggle' | 'text' | 'list' | 'tuple' | 'record'} Control
 */

/** @typedef {ParamValue} Value */

/**
 * A value the panel won't give, where in it (`[1, 'depth']`), and why, the place written first
 * (`[1][:depth] must be at least 0.1`).
 * @typedef {{ error: string, path: PathStep[] }} Refusal
 */

/**
 * @param {Rule} rule
 * @returns {Control}
 */
export function controlOf(rule) {
  if (rule.type === 'array') return rule.tuple ? 'tuple' : 'list';
  if (rule.type === 'map') return 'record';
  if (rule.in) return 'select';
  if (rule.type === 'boolean') return 'toggle';
  if (rule.type === 'string') return 'text';
  return rule.min !== null && rule.max !== null ? 'slider' : 'number';
}

/**
 * The places of a value of parts, each with its rule and what labels its control: a tuple's
 * places (their titles, else their indexes) or a Map's fields (their titles, else their names).
 * @param {Rule} rule a tuple's or a Map's
 * @returns {{ step: PathStep, rule: Rule, label: string }[]}
 */
export function partsOf(rule) {
  if (rule.tuple) {
    return rule.tuple.map((place, index) => ({
      step: index,
      rule: place,
      label: place.title ?? String(index),
    }));
  }
  return (rule.fields ?? []).map((field) => ({
    step: field.name,
    rule: field,
    label: field.title ?? field.name,
  }));
}

/**
 * A number control's increment: the script's `step:`, else 1 for one between a `min` and a
 * `max` (a slider moved by a hand lands on whole numbers, not on 27.41112), or, for a range
 * narrower than 1, which a step of 1 couldn't move in, the power of ten that gives it at least
 * ten positions; any value for a number with no range. Finer still where the range's ends or
 * the parameter's default have more decimals: a control's steps count from its `min`, so 1.2 to
 * 4 by 1 reached neither 4 nor a default of 2, which the slider showed as 2.2.
 * @param {Rule | ParamSpec} rule
 * @returns {number | 'any'}
 */
export function stepOf(rule) {
  if (rule.step !== null) return rule.step;
  const { min, max } = rule;
  if (min === null || max === null || !(max > min)) return 'any';
  const range = max - min;
  const coarsest = range >= 1 ? 1 : 10 ** (Math.floor(Math.log10(range)) - 1);
  const marks = [min, max];
  if ('default_value' in rule && typeof rule.default_value === 'number') {
    marks.push(rule.default_value);
  }
  const steps = marks.map(decimalStepOf);
  return steps.includes(null) ? 'any' : Math.min(coarsest, .../** @type {number[]} */ (steps));
}

/** The decimal places a step may have: past them, a number is taken as having no grid. */
const MAX_PLACES = 9;

/**
 * The coarsest power of ten, 1 at most, that `n` is a whole multiple of (0.1 for 1.2, 1 for 40),
 * or null for a number of more than MAX_PLACES decimals.
 * @param {number} n
 * @returns {number | null}
 */
function decimalStepOf(n) {
  for (let places = 0; places <= MAX_PLACES; places += 1) {
    const scaled = n * 10 ** places;
    if (Math.abs(scaled - Math.round(scaled)) < 1e-9 * Math.max(1, Math.abs(scaled))) {
      return 10 ** -places;
    }
  }
  return null;
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
 * else its default (null when it has none, or the script computes it and no run took one).
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
 * What a new part of `rule` starts as: its first choice, else what is blank for its kind (a
 * number in its range, each of a tuple's places, each of a Map's fields).
 * @param {Rule} rule
 * @returns {Value}
 */
export function blankOf(rule) {
  if (rule.in) return rule.in[0];
  switch (rule.type) {
    case 'number': {
      // Zero, into its range
      return Math.min(Math.max(0, rule.min ?? -Infinity), rule.max ?? Infinity);
    }
    case 'boolean':
      return false;
    case 'array':
      return rule.tuple ? rule.tuple.map(blankOf) : [];
    case 'map':
      return Object.fromEntries((rule.fields ?? []).map((field) => [field.name, blankOf(field)]));
    default:
      return '';
  }
}

/**
 * What a new element of a list starts as: a copy of the last, else a blank one.
 * @param {Rule} rule a list's
 * @param {readonly Value[]} items
 * @returns {Value}
 */
export function newElement(rule, items) {
  if (items.length > 0) return structuredClone(items[items.length - 1]);
  return blankOf(/** @type {Rule} */ (rule.items));
}

/**
 * Whether a list may have an element added, or removed: its `max_items` and `min_items`.
 * @param {Rule} rule a list's
 * @param {number} count its elements now
 */
export const canAdd = (rule, count) => rule.max_items === null || count < rule.max_items;
/** @param {Rule} rule @param {number} count */
export const canRemove = (rule, count) => rule.min_items === null || count > rule.min_items;

/**
 * Whether `a` and `b` are one value: arrays and objects by what they hold.
 * @param {Value | null | undefined} a
 * @param {Value | null | undefined} b
 * @returns {boolean}
 */
export function sameValue(a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    return (
      Array.isArray(a) &&
      Array.isArray(b) &&
      a.length === b.length &&
      a.every((item, index) => sameValue(item, b[index]))
    );
  }
  if (isRecord(a) || isRecord(b)) {
    if (!isRecord(a) || !isRecord(b)) return false;
    const keys = Object.keys(a);
    return (
      keys.length === Object.keys(b).length &&
      keys.every((key) => Object.hasOwn(b, key) && sameValue(a[key], b[key]))
    );
  }
  return a === b;
}

/**
 * @param {unknown} value
 * @returns {value is { [field: string]: Value }}
 */
const isRecord = (value) => typeof value === 'object' && value !== null && !Array.isArray(value);

/**
 * `value` (the whole of it) with the part at `path` given `part`.
 * @param {Value | null} value
 * @param {PathStep[]} path
 * @param {Value} part
 * @returns {Value}
 */
export function withPart(value, path, part) {
  if (path.length === 0) return part;
  const [step, ...rest] = path;
  if (typeof step === 'number') {
    const items = Array.isArray(value) ? [...value] : [];
    items[step] = withPart(items[step] ?? null, rest, part);
    return items;
  }
  const fields = isRecord(value) ? { ...value } : {};
  fields[step] = withPart(Object.hasOwn(fields, step) ? fields[step] : null, rest, part);
  return fields;
}

/**
 * The part of `value` at `path`; null where it has none.
 * @param {Value | null} value
 * @param {PathStep[]} path
 * @returns {Value | null}
 */
export function partAt(value, path) {
  let part = value;
  for (const step of path) {
    if (typeof step === 'number') part = Array.isArray(part) ? (part[step] ?? null) : null;
    else part = isRecord(part) && Object.hasOwn(part, step) ? part[step] : null;
  }
  return part;
}

/**
 * The place `path` names, as the core writes it: `[1][:depth]`.
 * @param {PathStep[]} path
 */
export const placeOf = (path) =>
  path.map((step) => (typeof step === 'number' ? `[${step}]` : `[:${step}]`)).join('');

/**
 * What a control gave, as the parameter's value (a part of it, for a part's rule), or why the
 * script wouldn't take it and where.
 * @param {Rule} rule
 * @param {Value | null} input
 * @returns {{ value: Value } | Refusal}
 */
export function validate(rule, input) {
  const result = read(rule, input, []);
  if ('value' in result) return result;
  const place = placeOf(result.path);
  return { error: place ? `${place} ${result.error}` : result.error, path: result.path };
}

/**
 * @param {Rule} rule
 * @param {Value | null} input
 * @param {PathStep[]} path where `input` is in the value
 * @returns {{ value: Value } | Refusal}
 */
function read(rule, input, path) {
  if (rule.type === 'array') return readArray(rule, input, path);
  if (rule.type === 'map') return readMap(rule, input, path);
  const choices = rule.in;
  if (choices) {
    const choice = choices.find((listed) => String(listed) === String(input));
    return choice === undefined
      ? { error: `must be one of ${choices.join(', ')}`, path }
      : { value: choice };
  }
  if (rule.type === 'boolean') return { value: input === true || input === 'true' };
  if (rule.type === 'string') return { value: String(input ?? '') };
  const text = String(input ?? '').trim();
  const number = Number(text);
  if (text === '' || !Number.isFinite(number)) return { error: 'must be a number', path };
  if (rule.min !== null && number < rule.min)
    return { error: `must be at least ${rule.min}`, path };
  if (rule.max !== null && number > rule.max) return { error: `must be at most ${rule.max}`, path };
  return { value: number };
}

/**
 * @param {Rule} rule
 * @param {Value | null} input
 * @param {PathStep[]} path
 * @returns {{ value: Value } | Refusal}
 */
function readArray(rule, input, path) {
  if (!Array.isArray(input)) return { error: 'must be a list', path };
  if (rule.tuple && input.length !== rule.tuple.length) {
    return { error: `must have ${rule.tuple.length} items`, path };
  }
  if (rule.min_items !== null && input.length < rule.min_items) {
    return { error: `must have at least ${rule.min_items} items`, path };
  }
  if (rule.max_items !== null && input.length > rule.max_items) {
    return { error: `must have at most ${rule.max_items} items`, path };
  }
  /** @type {Value[]} */
  const items = [];
  for (const [index, item] of input.entries()) {
    const place = rule.tuple ? rule.tuple[index] : /** @type {Rule} */ (rule.items);
    const result = read(place, item, [...path, index]);
    if (!('value' in result)) return result;
    items.push(result.value);
  }
  return { value: items };
}

/**
 * @param {Rule} rule
 * @param {Value | null} input
 * @param {PathStep[]} path
 * @returns {{ value: Value } | Refusal}
 */
function readMap(rule, input, path) {
  if (!isRecord(input)) return { error: 'must be a record', path };
  /** @type {{ [field: string]: Value }} */
  const fields = {};
  for (const field of rule.fields ?? []) {
    const given = Object.hasOwn(input, field.name) ? input[field.name] : null;
    const result = read(field, given, [...path, field.name]);
    if (!('value' in result)) return result;
    fields[field.name] = result.value;
  }
  return { value: fields };
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
