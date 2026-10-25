import { Box3, GreaterDepth, Mesh } from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { describe, expect, it, vi } from 'vitest';
import {
  GHOST_OPACITY,
  isDracoCompressed,
  ownMaterials,
  sceneOf,
  SEEN_THROUGH_OPACITY,
} from './model.js';
import { dracoModelOf, HIGHLIGHTED_PIN, modelOf, PARTS_WITH_GHOST } from './models.test-helper.js';
import { LIGHT } from './theme.js';

/** @import { MeshBasicMaterial, MeshStandardMaterial } from 'three' */
/** @import { SceneModel } from './types.js' */
/** @import { Vector3 } from 'three' */

/**
 * A point's coordinates to a thousandth of a millimetre, -0 as 0.
 * @param {Vector3} point
 */
const mm = (point) => point.toArray().map((v) => Math.round(v * 1000) / 1000 + 0);

/**
 * The scene of the core's preview of `source`.
 * @param {string} source
 * @returns {Promise<SceneModel>}
 */
async function sceneOfScript(source) {
  const scene = await sceneOf(await modelOf(source), new GLTFLoader(), LIGHT);
  if (!scene) throw new Error('no scene');
  scene.root.updateMatrixWorld(true);
  return scene;
}

describe('sceneOf a GLB', () => {
  it("puts the Solids back in the script's coordinates: millimetres, Z up", async () => {
    const scene = await sceneOfScript('cube([20, 10, 2])');
    const box = new Box3().setFromObject(scene.shapes[0].mesh);
    expect(mm(box.min)).toEqual([0, 0, 0]);
    expect(mm(box.max)).toEqual([20, 10, 2]);
  });

  it("knows each mesh's part, with its colour and edges, and sees a ghost through", async () => {
    const scene = await sceneOfScript(PARTS_WITH_GHOST);
    const parts = scene.shapes.map((shape) => shape.part);
    expect(parts.filter((part) => part === 'bolt')).toHaveLength(2);
    expect(parts.filter((part) => part === 'plate')).toHaveLength(1);
    expect(parts.filter((part) => part === null)).toHaveLength(1);
    const bolts = scene.shapes.filter((shape) => shape.part === 'bolt');
    expect(bolts[0].color.getHexString()).toBe('cc3333');
    // Each copy has a material of its own, so tinting one part leaves the others
    expect(bolts[0].mesh.material).not.toBe(bolts[1].mesh.material);
    expect(bolts.every((shape) => shape.edges !== null)).toBe(true);
    // Drawn behind their edges, which would be lost in them at the same depth
    expect(
      bolts.every(
        (shape) => /** @type {MeshStandardMaterial} */ (shape.mesh.material).polygonOffset,
      ),
    ).toBe(true);
    const ghost = scene.shapes.find((shape) => shape.ghost);
    const material = /** @type {MeshStandardMaterial} */ (ghost?.mesh.material);
    expect(material.transparent).toBe(true);
    expect(material.opacity).toBe(GHOST_OPACITY);
    expect(ghost?.edges).toBeNull();
  });

  it("draws a highlighted solid in the highlight's colour, and a copy seen through what hides it", async () => {
    const scene = await sceneOfScript(HIGHLIGHTED_PIN);
    const pin = scene.shapes.find((shape) => shape.part === 'pin');
    const box = scene.shapes.find((shape) => shape.part === 'box');
    if (!pin || !box) throw new Error('no pin or box');
    // A part as any other, with its edges, in the highlight's colour
    expect(pin.color.getHexString()).toBe(LIGHT.highlight.slice(1));
    expect(pin.edges).not.toBeNull();
    const copy = pin.seenThrough;
    expect(copy?.parent).toBe(pin.mesh);
    expect(copy?.geometry).toBe(pin.mesh.geometry);
    // Drawn only where something nearer was drawn: behind it
    expect(/** @type {MeshBasicMaterial} */ (copy?.material)).toMatchObject({
      transparent: true,
      opacity: SEEN_THROUGH_OPACITY,
      depthFunc: GreaterDepth,
      depthWrite: false,
    });
    expect(ownMaterials(scene).has(/** @type {MeshBasicMaterial} */ (copy?.material))).toBe(true);
    expect(box.seenThrough).toBeNull();
  });

  it("knows a part whose name the loader changes, by its GLB node's", async () => {
    // The loader names the objects "Lid_v20" and "abc1"
    const scene = await sceneOfScript(
      '[cube(1).named("Lid v2.0"), cube(2).translate(x: 5).named("a/b:c[1]")]',
    );
    expect(scene.shapes.map((shape) => shape.part)).toEqual(['Lid v2.0', 'a/b:c[1]']);
  });

  it('tells a Draco-compressed GLB', async () => {
    const plain = await modelOf('cube(2)');
    const draco = await dracoModelOf('cube(2)');
    if (plain.kind !== '3d' || draco.kind !== '3d') throw new Error('not 3D');
    expect(isDracoCompressed(plain.glb)).toBe(false);
    expect(isDracoCompressed(draco.glb)).toBe(true);
  });
});

describe('sceneOf an SVG', () => {
  it('draws each filled shape on the XY plane, Y up again, named by its id, with its outline', async () => {
    // three.js warns of a deprecated call, as of SVGLoader.createShapes
    const warn = vi.spyOn(console, 'warn');
    const scene = await sceneOfScript('[square(10).named("plate"), line([0, 0], [5, 5])]');
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
    expect(scene.kind).toBe('2d');
    const plate = scene.shapes.find((shape) => shape.part === 'plate');
    if (!plate) throw new Error('no plate');
    expect(plate.mesh).toBeInstanceOf(Mesh);
    expect(plate.edges).not.toBeNull();
    const box = new Box3().setFromObject(plate.mesh);
    expect(mm(box.min)).toEqual([0, 0, 0]);
    expect(mm(box.max)).toEqual([10, 10, 0]);
    expect(/** @type {MeshBasicMaterial} */ (plate.mesh.material).polygonOffset).toBe(true);
    // The open line is drawn, not filled: no shape of its own
    expect(scene.shapes).toHaveLength(1);
  });
});

it('a model of nothing has no scene', async () => {
  expect(await sceneOf({ kind: 'none' }, new GLTFLoader(), LIGHT)).toBeNull();
});
