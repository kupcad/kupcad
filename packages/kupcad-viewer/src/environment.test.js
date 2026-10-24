import { describe, expect, it } from 'vitest';
import { stops } from './environment.js';

describe('stops', () => {
  it("puts a plate's lines every step from the origin, and on its edges", () => {
    const across = stops(128, 10);
    expect(across).toContain(0);
    expect(across[0]).toBe(-128);
    expect(across.at(-1)).toBe(128);
    expect(across.slice(1, -1).every((at) => at % 10 === 0)).toBe(true);
    // It drew one at 132, past the edge
    expect(Math.max(...across)).toBe(128);
    expect(across).toHaveLength(27);
  });

  it("draws an edge that is a whole step once, and a fine grid's lines where they belong", () => {
    expect(stops(50, 5)).toEqual([
      -50, -45, -40, -35, -30, -25, -20, -15, -10, -5, 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50,
    ]);
    // Summing 0.1 twenty times drifted off the grid's own multiples
    const fine = stops(1, 0.1);
    expect(fine).toHaveLength(21);
    expect(fine[13]).toBe(3 * 0.1);
  });
});
