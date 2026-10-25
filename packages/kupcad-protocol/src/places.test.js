import { describe, expect, it } from 'vitest';
import { characterAt } from './places.js';

describe('characterAt', () => {
  it('counts a column of UTF-8 bytes from 1 as UTF-16 code units from 0', () => {
    expect(characterAt('cube(10)', 1)).toBe(0);
    expect(characterAt('cube(10)', 6)).toBe(5);
    // é is two bytes and one unit: the `=` after it is byte 4
    expect(characterAt('é = 1', 4)).toBe(2);
    // An emoji is four bytes and two units: the `+` after it is byte 8
    expect(characterAt('"🙂" + x', 8)).toBe(5);
  });

  it("gives the line's end for a column past it", () => {
    expect(characterAt('ab', 10)).toBe(2);
    expect(characterAt('', 1)).toBe(0);
  });
});
