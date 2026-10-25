import { expect, it } from 'vitest';
import { errorText } from './error-text.js';

it("is an Error's message, and anything else thrown as text", () => {
  expect(errorText(new TypeError('not a function'))).toBe('not a function');
  expect(errorText('a string')).toBe('a string');
  expect(errorText(404)).toBe('404');
  expect(errorText(undefined)).toBe('undefined');
});
