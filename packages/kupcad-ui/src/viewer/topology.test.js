import {
  BoxGeometry,
  BufferGeometry,
  CylinderGeometry,
  EdgesGeometry,
  Float32BufferAttribute,
  PlaneGeometry,
  TorusKnotGeometry,
} from 'three';
import { describe, expect, it } from 'vitest';
import { EDGE_ANGLE_DEG, featureEdgesOf, topologyOf } from './topology.js';

/**
 * A geometry's line segments, each as its ends (to a thousandth, the lower first), sorted: the
 * same segments in any order and either way round are equal.
 * @param {BufferGeometry} geometry
 */
function segments(geometry) {
  const p = geometry.getAttribute('position').array;
  /** @param {number} at */
  const point = (at) => [p[at], p[at + 1], p[at + 2]].map((x) => x.toFixed(3)).join();
  const out = [];
  for (let at = 0; at < p.length; at += 6) {
    const [a, b] = [point(at), point(at + 3)].toSorted();
    out.push(`${a}|${b}`);
  }
  return out.toSorted();
}

describe('feature edges', () => {
  it.each([
    ['a box', new BoxGeometry(2, 4, 6)],
    ['a box whose faces have corners of their own', new BoxGeometry(2, 4, 6).toNonIndexed()],
    ['a prism: its ends, not its sides', new CylinderGeometry(1, 1, 2, 32, 3)],
    ['an open sheet: its border', new PlaneGeometry(3, 3, 4, 4)],
    ['a knot, turning everywhere', new TorusKnotGeometry(10, 3, 64, 8)],
  ])("are three.js's EdgesGeometry's on %s", (_, geometry) => {
    const ours = segments(featureEdgesOf(geometry));
    expect(ours.length).toBeGreaterThan(0);
    expect(ours).toEqual(segments(new EdgesGeometry(geometry, EDGE_ANGLE_DEG)));
  });

  it('leave out a degenerate triangle: two of its corners are one point', () => {
    const geometry = new BufferGeometry().setAttribute(
      'position',
      new Float32BufferAttribute([0, 0, 0, 1, 0, 0, 1, 0, 0], 3),
    );
    expect(featureEdgesOf(geometry).getAttribute('position').count).toBe(0);
  });
});

describe('a topology', () => {
  it('is found once per geometry', () => {
    const geometry = new BoxGeometry(1, 1, 1);
    expect(topologyOf(geometry)).toBe(topologyOf(geometry));
    featureEdgesOf(geometry);
    expect(topologyOf(geometry)).toBe(topologyOf(geometry));
  });
});
