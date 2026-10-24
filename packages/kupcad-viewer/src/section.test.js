import { Group, LineBasicMaterial, Sphere, Vector3 } from 'three';
import { expect, it } from 'vitest';
import { SectionView } from './section.js';
import { LIGHT } from './theme.js';

/** @import { SceneModel } from './types.js' */

/** A solid's model with no shapes: what the section does to the plane and the cap alone. */
const SOLIDS = /** @type {SceneModel} */ ({
  kind: '3d',
  root: new Group(),
  shapes: [],
  edgeMaterial: new LineBasicMaterial(),
});

it('caps the cut where the plane crosses the model, wherever the model is', () => {
  const view = new SectionView(LIGHT);
  const bounds = new Sphere(new Vector3(500, -300, 40), 10);
  view.apply({ axis: 'z', offset: 2 }, SOLIDS, bounds, { capped: true, also: [] });
  expect(view.cap.visible).toBe(true);
  expect(view.cap.position.toArray()).toEqual([500, -300, 2]);
  expect(view.cap.scale.x).toBeGreaterThan(bounds.radius * 2);
});

it('cuts at the plane without a cap, in a wireframe', () => {
  const view = new SectionView(LIGHT);
  const edges = new LineBasicMaterial();
  view.apply({ axis: 'x', offset: 5, flip: true }, SOLIDS, new Sphere(new Vector3(), 10), {
    capped: false,
    also: [edges],
  });
  expect(view.clipping).toBe(true);
  expect(view.cap.visible).toBe(false);
  expect(edges.clippingPlanes).toEqual([view.plane]);
  // Flipped, what is below x = 5 is cut away: the plane keeps x > 5
  expect(view.plane.distanceToPoint(new Vector3(6, 0, 0))).toBeGreaterThan(0);
  expect(view.plane.distanceToPoint(new Vector3(4, 0, 0))).toBeLessThan(0);
});

it("doesn't cut a drawing, and takes the cut away with the section", () => {
  const view = new SectionView(LIGHT);
  const edges = new LineBasicMaterial();
  const drawing = /** @type {SceneModel} */ ({ ...SOLIDS, kind: '2d' });
  const options = { capped: true, also: [edges] };
  view.apply({ axis: 'z', offset: 0 }, drawing, new Sphere(new Vector3(), 10), options);
  expect(view.clipping).toBe(false);
  expect(view.cap.visible).toBe(false);
  view.apply({ axis: 'z', offset: 0 }, SOLIDS, new Sphere(new Vector3(), 10), options);
  view.apply(null, SOLIDS, new Sphere(new Vector3(), 10), options);
  expect(view.clipping).toBe(false);
  expect(edges.clippingPlanes).toBeNull();
});
