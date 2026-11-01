import {
  BackSide,
  BoxGeometry,
  Color,
  Group,
  LineBasicMaterial,
  Mesh,
  MeshStandardMaterial,
  Sphere,
  Vector3,
} from 'three';
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
  highlightEdges: null,
});

it('caps the cut where the plane crosses the model, wherever the model is', () => {
  const view = new SectionView(LIGHT);
  const bounds = new Sphere(new Vector3(500, -300, 40), 10);
  view.apply({ axis: 'z', offset: 2 }, SOLIDS, bounds, { capped: true, also: [] });
  expect(view.cap.visible).toBe(true);
  expect(view.cap.position.x).toBe(500);
  expect(view.cap.position.y).toBe(-300);
  expect(view.cap.position.z).toBeCloseTo(2, 2);
  expect(view.cap.scale.x).toBeGreaterThan(bounds.radius * 2);
});

it('keeps a face at the offset, either way, and is seen from the side cut away', () => {
  // Whether such a face was clipped came down to each pixel's rounding: the cap in streaks
  const view = new SectionView(LIGHT);
  const bounds = new Sphere(new Vector3(), 10);
  for (const flip of [false, true]) {
    view.apply({ axis: 'z', offset: 4, flip }, SOLIDS, bounds, { capped: true, also: [] });
    const onPlane = view.plane.distanceToPoint(new Vector3(1, 2, 4));
    expect(onPlane).toBeGreaterThan(0);
    expect(onPlane).toBeLessThan(0.01);
    // Past the offset, toward what is cut away, is cut
    expect(view.plane.distanceToPoint(new Vector3(1, 2, flip ? 3.9 : 4.1))).toBeLessThan(0);
  }
  // Its normal is the plane's, toward what is kept: from the side cut away, its back
  expect(view.cap.getWorldDirection(new Vector3()).dot(view.plane.normal)).toBeCloseTo(1);
  expect(/** @type {MeshStandardMaterial} */ (view.cap.material).side).toBe(BackSide);
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

it("moves the plane alone over the same model: its counters stay, and its materials' programs", () => {
  const view = new SectionView(LIGHT);
  const mesh = new Mesh(new BoxGeometry(10, 10, 10), new MeshStandardMaterial());
  const model = /** @type {SceneModel} */ ({
    kind: '3d',
    root: new Group().add(mesh),
    shapes: [
      {
        mesh,
        edges: null,
        part: 'box',
        ghost: false,
        seenThrough: null,
        color: new Color(),
        opacity: 1,
      },
    ],
    edgeMaterial: new LineBasicMaterial(),
    highlightEdges: null,
  });
  const bounds = new Sphere(new Vector3(), 10);
  const options = { capped: true, also: [] };
  view.apply({ axis: 'z', offset: 0 }, model, bounds, options);
  const counters = [...mesh.children];
  const version = mesh.material.version;
  view.apply({ axis: 'z', offset: 3 }, model, bounds, options);
  expect(mesh.children).toEqual(counters);
  // A material made to update compiles its program again
  expect(mesh.material.version).toBe(version);
  expect(view.cap.position.z).toBeCloseTo(3, 2);
  // Cut no more, it stops clipping, once
  view.apply(null, model, bounds, options);
  expect(mesh.children).toEqual([]);
  expect(mesh.material.clippingPlanes).toBeNull();
  expect(mesh.material.version).toBe(version + 1);
});
