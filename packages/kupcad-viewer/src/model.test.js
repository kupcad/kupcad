import { Box3, Mesh } from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { describe, expect, it } from 'vitest';
import { GHOST_OPACITY, isDracoCompressed, sceneOf } from './model.js';
import { dracoModelOf, modelOf, PARTS_WITH_GHOST } from './models.test-helper.js';
import { LIGHT } from './theme.js';

/** @import { MeshStandardMaterial } from 'three' */
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
    const ghost = scene.shapes.find((shape) => shape.ghost);
    const material = /** @type {MeshStandardMaterial} */ (ghost?.mesh.material);
    expect(material.transparent).toBe(true);
    expect(material.opacity).toBe(GHOST_OPACITY);
    expect(ghost?.edges).toBeNull();
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
    const scene = await sceneOfScript('[square(10).named("plate"), line([0, 0], [5, 5])]');
    expect(scene.kind).toBe('2d');
    const plate = scene.shapes.find((shape) => shape.part === 'plate');
    if (!plate) throw new Error('no plate');
    expect(plate.mesh).toBeInstanceOf(Mesh);
    expect(plate.edges).not.toBeNull();
    const box = new Box3().setFromObject(plate.mesh);
    expect(mm(box.min)).toEqual([0, 0, 0]);
    expect(mm(box.max)).toEqual([10, 10, 0]);
    // The open line is drawn, not filled: no shape of its own
    expect(scene.shapes).toHaveLength(1);
  });
});

it('a model of nothing has no scene', async () => {
  expect(await sceneOf({ kind: 'none' }, new GLTFLoader(), LIGHT)).toBeNull();
});
