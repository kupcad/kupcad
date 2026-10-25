import { describe, expect, it } from 'vitest';
import { BRACKET, schemaOf } from './fixtures.test-helper.js';
import {
  controlOf,
  groupsOf,
  isOverridden,
  shownValue,
  stepOf,
  validate,
  withOverride,
  withoutOverride,
} from './params.js';

/** @import { ParamSpec } from '@kupcad/protocol/types' */

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
    expect(validate(width, 5)).toEqual({ error: 'must be at least 10' });
    expect(validate(width, '101')).toEqual({ error: 'must be at most 100' });
    expect(validate(width, '')).toEqual({ error: 'must be a number' });
    expect(validate(width, 'wide')).toEqual({ error: 'must be a number' });
  });

  it('takes a listed value as it is listed, a boolean and text', async () => {
    const size = await spec('size');
    expect(validate(size, 'm5')).toEqual({ value: 'm5' });
    expect(validate(size, 'm6')).toEqual({ error: 'must be one of m3, m4, m5' });
    expect(validate(await spec('hollow'), true)).toEqual({ value: true });
    expect(validate(await spec('label'), 'B')).toEqual({ value: 'B' });
  });
});

it('overrides are set and taken away by name, the rest kept', () => {
  const set = withOverride({ width: 40 }, 'label', 'B');
  expect(set).toEqual({ width: 40, label: 'B' });
  expect(withoutOverride(set, 'width')).toEqual({ label: 'B' });
});
