import { describe, expect, it } from 'vitest';
import { Box3, Vector3 } from 'three';
import { axesOf, stops } from './environment.js';

/** @import { Group, LineBasicMaterial, LineSegments } from 'three' */

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

/**
 * Each axis's colour and its two ends.
 * @param {Group} axes
 */
const linesOf = (axes) =>
  axes.children.map((child) => {
    const line = /** @type {LineSegments} */ (child);
    const position = line.geometry.getAttribute('position');
    // To a thousandth of a millimetre: the buffer holds 32-bit floats
    /** @param {number} i */
    const end = (i) =>
      [position.getX(i), position.getY(i), position.getZ(i)].map(
        (v) => Math.round(v * 1000) / 1000,
      );
    return {
      color: `#${/** @type {LineBasicMaterial} */ (line.material).color.getHexString()}`,
      from: end(0),
      to: end(1),
    };
  });

describe('the axes', () => {
  it('run through the origin across the floor, X red, Y green, Z blue up from it', () => {
    const box = new Box3(new Vector3(-10, -10, 0), new Vector3(10, 10, 5));
    const [x, y, z] = linesOf(axesOf('grid', box, { width: 256, depth: 256 }));
    // The grid's side for a model 10 mm from the origin is 20
    expect(x).toMatchObject({ color: '#e5484d', from: [-10, 0, 0.02], to: [10, 0, 0.02] });
    expect(y).toMatchObject({ color: '#30a46c', from: [0, -10, 0.02], to: [0, 10, 0.02] });
    expect(z).toMatchObject({ color: '#3e63dd', from: [0, 0, 0.02], to: [0, 0, 5] });
  });

  it("span a plate as far as its longer side, and a model's grid size with no floor", () => {
    const box = new Box3(new Vector3(0, 0, 0), new Vector3(1, 1, 1));
    expect(linesOf(axesOf('plate', box, { width: 300, depth: 200 }))[0].to[0]).toBe(150);
    expect(linesOf(axesOf('none', box, { width: 300, depth: 200 }))[0].to[0]).toBe(1);
  });
});
