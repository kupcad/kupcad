import { expect, it } from 'vitest';
import { Recent } from './recent.js';

it('keeps the most recently shown, letting the least recent go past as many as it keeps', () => {
  const recent = /** @type {Recent<number>} */ (new Recent(3));
  recent.keep('a', 1);
  recent.keep('b', 2);
  recent.keep('c', 3);
  // Read, a is the most recent: b is the least
  expect(recent.get('a')).toBe(1);
  recent.keep('d', 4);
  expect([recent.get('b'), recent.size]).toEqual([undefined, 3]);
  // Kept again, c is the most recent, with its new value
  recent.keep('c', 30);
  recent.keep('e', 5);
  expect([recent.get('a'), recent.get('c'), recent.get('d'), recent.get('e')]).toEqual([
    undefined,
    30,
    4,
    5,
  ]);
});
