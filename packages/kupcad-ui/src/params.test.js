import { describe, expect, it } from 'vitest';
import { BRACKET, schemaOf } from './fixtures.test-helper.js';
import {
  blankOf,
  canAdd,
  canRemove,
  controlOf,
  groupsOf,
  isOverridden,
  newElement,
  partAt,
  partsOf,
  placeOf,
  sameValue,
  shownValue,
  stepOf,
  validate,
  withOverride,
  withoutOverride,
  withPart,
} from './params.js';

/** @import { ParamSpec, Rule } from '@kupcad/protocol/types' */

/**
 * The parameter of the bracket's schema named `name`.
 * @param {string} name
 * @returns {Promise<ParamSpec>}
 */
async function spec(name) {
  const found = (await schemaOf(BRACKET)).parameters.find((parameter) => parameter.name === name);
  if (!found) throw new Error(`no parameter ${name}`);
  return found;
}

describe('the controls', () => {
  it('are a slider between a min and a max, a number, a select of listed values, a toggle, a text', async () => {
    const { parameters } = await schemaOf(BRACKET);
    expect(Object.fromEntries(parameters.map((p) => [p.name, controlOf(p)]))).toEqual({
      width: 'slider',
      height: 'number',
      hollow: 'toggle',
      label: 'text',
      size: 'select',
    });
  });

  it('step by 1 between a min and a max, unless the script says, or the range is narrower', async () => {
    const { parameters } =
      await schemaOf(`a = param(:a, default: 20, validate: { min: 10, max: 100 })
b = param(:b, default: 2, validate: { min: 0, max: 5 }, step: 0.25)
c = param(:c, default: 0.2, validate: { min: 0.1, max: 0.5 })
d = param(:d, default: 0.002, validate: { min: 0, max: 0.05 })
e = param(:e, default: 3)
cube(a + b + c + d + e)
`);
    // A slider of 0.1 to 0.5 by 1 couldn't move: it gets ten positions at least
    expect(parameters.map(stepOf)).toEqual([1, 0.25, 0.01, 0.001, 'any']);
  });

  it('step finely enough that the range reaches its max, and its default, from its min', async () => {
    const { parameters } =
      await schemaOf(`wall = param(:wall, default: 2, validate: { min: 1.2, max: 4 })
fit = param(:fit, default: 0.25, validate: { min: 0, max: 10 })
cube(wall + fit)
`);
    // Counted from 1.2, steps of 1 reached 2.2 and 3.2: neither 4 nor the default
    expect(parameters.map(stepOf)).toEqual([0.1, 0.01]);
  });

  it('group as the script names the groups, those without one first', async () => {
    const groups = groupsOf((await schemaOf(BRACKET)).parameters);
    expect(groups.map(({ group, parameters }) => [group, parameters.map((p) => p.name)])).toEqual([
      [null, ['hollow', 'label']],
      ['Size', ['width', 'height']],
      ['Holes', ['size']],
    ]);
  });

  it("show the panel's value, else the run's, else the default", async () => {
    const width = await spec('width');
    expect(shownValue(width, {}, {})).toBe(20);
    expect(shownValue(width, {}, { width: 25 })).toBe(25);
    expect(shownValue(width, { width: 40 }, { width: 25 })).toBe(40);
    // A false set in the panel is a value, not none
    expect(shownValue(await spec('hollow'), { hollow: false }, { hollow: true })).toBe(false);
  });
});

it("reads a parameter named like an Object's member as any other: its own value, set or not", async () => {
  const { parameters } = await schemaOf(
    'constructor = param(:constructor, default: 3)\ncube(constructor)\n',
  );
  const [named] = parameters;
  // `{}.constructor` is Object, and `"constructor" in {}` true
  expect(shownValue(named, {}, {})).toBe(3);
  expect(isOverridden({}, 'constructor')).toBe(false);
  expect(isOverridden({ constructor: 4 }, 'constructor')).toBe(true);
  expect(shownValue(named, { constructor: 4 }, {})).toBe(4);
});

describe('validate', () => {
  it('takes a number within its min and max, saying why it refuses one that is not', async () => {
    const width = await spec('width');
    expect(validate(width, '40')).toEqual({ value: 40 });
    expect(validate(width, 5)).toEqual({ error: 'must be at least 10', path: [] });
    expect(validate(width, '101')).toEqual({ error: 'must be at most 100', path: [] });
    expect(validate(width, '')).toEqual({ error: 'must be a number', path: [] });
    expect(validate(width, 'wide')).toEqual({ error: 'must be a number', path: [] });
  });

  it('takes a listed value as it is listed, a boolean and text', async () => {
    const size = await spec('size');
    expect(validate(size, 'm5')).toEqual({ value: 'm5' });
    expect(validate(size, 'm6')).toEqual({ error: 'must be one of m3, m4, m5', path: [] });
    expect(validate(await spec('hollow'), true)).toEqual({ value: true });
    expect(validate(await spec('label'), 'B')).toEqual({ value: 'B' });
  });
});

it('overrides are set and taken away by name, the rest kept', () => {
  const set = withOverride({ width: 40 }, 'label', 'B');
  expect(set).toEqual({ width: 40, label: 'B' });
  expect(withoutOverride(set, 'width')).toEqual({ label: 'B' });
});

/** Parameters of each shape a value has, with rules. */
const SHAPES = `xs = param(:xs, default: [10, 20], validate: { items: { type: :number, min: 5 }, max_items: 3 })
pos = param(:pos, default: [0, 0], validate: { tuple: [{ type: :number, title: "X" }, { type: :number, min: 0, max: 200 }] })
pts = param(:pts, default: [[0, 0], [10, 0]], validate: { min_items: 2, items: { tuple: [:number, { type: :number, max: 200 }] } })
at = param(:at, default: { x: 0, y: 1 })
cuts = param(:cuts, default: [{ type: "slot", depth: 5 }], validate: { items: { fields: { type: { type: :string, in: ["slot", "hole"] }, depth: { type: :number, min: 0.1 } } } })
cube(1)
`;

/** The parameters of SHAPES, by name. */
async function shapes() {
  const { parameters } = await schemaOf(SHAPES);
  return Object.fromEntries(parameters.map((parameter) => [parameter.name, parameter]));
}

describe('a value of parts', () => {
  it('is a list, a tuple, a list of tuples, a record or a list of records', async () => {
    const { xs, pos, pts, at, cuts } = await shapes();
    expect([xs, pos, pts, at, cuts].map((parameter) => controlOf(parameter))).toEqual([
      'list',
      'tuple',
      'list',
      'record',
      'list',
    ]);
    // A tuple's places by their titles, else their indexes; a Map's fields by their names
    expect(partsOf(pos).map((part) => [part.step, part.label])).toEqual([
      [0, 'X'],
      [1, '1'],
    ]);
    expect(partsOf(at).map((part) => [part.step, part.label])).toEqual([
      ['x', 'x'],
      ['y', 'y'],
    ]);
    expect(controlOf(/** @type {Rule} */ (cuts.items?.fields?.[0]))).toBe('select');
  });

  it('takes a value by its rules, refusing one by its place', async () => {
    const { xs, pos, pts, cuts } = await shapes();
    expect(validate(xs, ['7', 20])).toEqual({ value: [7, 20] });
    expect(validate(xs, [7, 2])).toEqual({ error: '[1] must be at least 5', path: [1] });
    expect(validate(xs, [5, 6, 7, 8])).toEqual({ error: 'must have at most 3 items', path: [] });
    expect(validate(pos, [1])).toEqual({ error: 'must have 2 items', path: [] });
    expect(validate(pos, ['1', '-1'])).toEqual({ error: '[1] must be at least 0', path: [1] });
    expect(validate(pts, [[0, 0]])).toEqual({ error: 'must have at least 2 items', path: [] });
    expect(
      validate(pts, [
        [0, 0],
        [1, 250],
      ]),
    ).toEqual({ error: '[1][1] must be at most 200', path: [1, 1] });
    expect(validate(cuts, [{ type: 'hole', depth: '2' }])).toEqual({
      value: [{ type: 'hole', depth: 2 }],
    });
    expect(validate(cuts, [{ type: 'hole' }])).toEqual({
      error: '[0][:depth] must be a number',
      path: [0, 'depth'],
    });
    expect(validate(cuts, [{ type: 'pocket', depth: 1 }])).toEqual({
      error: '[0][:type] must be one of slot, hole',
      path: [0, 'type'],
    });
  });

  it('adds a copy of the last element, else a blank one, as its min_items and max_items allow', async () => {
    const { xs, pts, cuts } = await shapes();
    expect(newElement(xs, [7, 8])).toBe(8);
    // Zero, into its range
    expect(newElement(xs, [])).toBe(5);
    expect(newElement(pts, [])).toEqual([0, 0]);
    expect(newElement(cuts, [])).toEqual({ type: 'slot', depth: 0.1 });
    expect(blankOf(/** @type {Rule} */ ({ ...xs, type: 'boolean', in: null }))).toBe(false);
    const last = [1, 2];
    const added = /** @type {number[]} */ (newElement(pts, [last]));
    added[0] = 9;
    expect(last).toEqual([1, 2]);
    expect([canAdd(xs, 2), canAdd(xs, 3)]).toEqual([true, false]);
    expect([canRemove(pts, 3), canRemove(pts, 2), canRemove(xs, 0)]).toEqual([true, false, true]);
  });

  it('puts a part in a value, reads it, and names its place as the core does', () => {
    const value = [{ type: 'slot', depth: 5 }];
    expect(withPart(value, [0, 'depth'], 6)).toEqual([{ type: 'slot', depth: 6 }]);
    expect(value).toEqual([{ type: 'slot', depth: 5 }]);
    expect(withPart([1, 2], [1], 5)).toEqual([1, 5]);
    expect(withPart(null, ['x'], 1)).toEqual({ x: 1 });
    expect(partAt(value, [0, 'type'])).toBe('slot');
    expect(partAt(value, [3, 'type'])).toBeNull();
    expect(placeOf([1, 'depth'])).toBe('[1][:depth]');
  });

  it('is the same value as another by what it holds', () => {
    expect(sameValue([1, [2, 'a']], [1, [2, 'a']])).toBe(true);
    expect(sameValue([1, [2]], [1, [3]])).toBe(false);
    expect(sameValue({ x: 1, y: [2] }, { y: [2], x: 1 })).toBe(true);
    expect(sameValue({ x: 1 }, { x: 1, y: 2 })).toBe(false);
    expect(sameValue([1], { 0: 1 })).toBe(false);
    expect(sameValue(null, null)).toBe(true);
  });
});
