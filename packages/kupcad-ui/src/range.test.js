import { expect, it } from 'vitest';
import { fillOf } from './range.js';

it("is the value's share of the span, as a percentage", () => {
  expect(fillOf(25, 0, 100)).toBe('25%');
  expect(fillOf('7.5', 5, 15)).toBe('25%');
  expect(fillOf(-2, -4, 4)).toBe('25%');
  expect(fillOf(60)).toBe('60%');
  // A rule's bound left out is the browser's own
  expect(fillOf(60, null, null)).toBe('60%');
});

it('holds a value outside the span to its ends', () => {
  expect(fillOf(-10, 0, 10)).toBe('0%');
  expect(fillOf(99, 0, 10)).toBe('100%');
});

it('is half way for no value, as the browser puts the thumb', () => {
  expect(fillOf(null, 0, 10)).toBe('50%');
  expect(fillOf('', 0, 10)).toBe('50%');
  expect(fillOf('x', 0, 10)).toBe('50%');
});

it('is empty for a span that is none', () => {
  expect(fillOf(3, 5, 5)).toBe('0%');
  expect(fillOf(3, 10, 0)).toBe('0%');
  expect(fillOf(3, 'a', 10)).toBe('0%');
});
