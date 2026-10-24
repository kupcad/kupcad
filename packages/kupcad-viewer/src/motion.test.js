import { Vector3 } from 'three';
import { describe, expect, it } from 'vitest';
import { CameraMove, easeInOut, sameDirection, unit } from './motion.js';

/** @import { Pose } from './motion.js' */

/**
 * A pose looking at `target` from `direction`, `distance` away.
 * @param {[number, number, number]} direction
 * @param {number} distance
 * @param {[number, number, number]} [target]
 * @returns {Pose}
 */
const pose = (direction, distance, target = [0, 0, 0]) => ({
  target: new Vector3(...target),
  direction: unit(direction),
  distance,
  halfHeight: distance / 2,
});

describe('a camera move', () => {
  it('eases in and out, from its start to its end', () => {
    expect(easeInOut(0)).toBe(0);
    expect(easeInOut(0.5)).toBe(0.5);
    expect(easeInOut(1)).toBe(1);
    expect(easeInOut(0.1)).toBeLessThan(0.1);
    expect(easeInOut(0.9)).toBeGreaterThan(0.9);
  });

  it('turns round what it looks at, the distance eased: top to bottom passes beside the model', () => {
    const move = new CameraMove(
      pose([0, -1e-4, 1], 10),
      pose([0, -1e-4, -1], 30, [4, 0, 0]),
      1000,
      200,
    );
    const start = move.at(1000);
    expect(start.done).toBe(false);
    expect(start.pose.direction.z).toBeCloseTo(1, 6);
    const half = move.at(1100).pose;
    // A unit direction at right angles to both ends: the camera is beside the model, not in it
    expect(half.direction.length()).toBeCloseTo(1, 9);
    expect(Math.abs(half.direction.z)).toBeLessThan(0.01);
    expect(half.distance).toBeCloseTo(20, 9);
    expect(half.target.x).toBeCloseTo(2, 9);
    const end = move.at(1300);
    expect(end.done).toBe(true);
    expect(end.pose).toBe(move.to);
  });

  it('tells one direction from another, a named view from a turn off it', () => {
    expect(sameDirection(unit([0, 0, 1]), unit([0, -1e-4, 1]))).toBe(true);
    expect(sameDirection(unit([1, -1, 1]), unit([1, -1, 1.01]))).toBe(false);
  });
});
