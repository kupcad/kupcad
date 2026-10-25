import { Color, LineBasicMaterial } from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { describe, expect, it } from 'vitest';
import {
  applyRenderMode,
  applySelection,
  applyTheme,
  SELECTION_TINT,
  XRAY_OPACITY,
} from './appearance.js';
import { GHOST_OPACITY, sceneOf } from './model.js';
import { HIGHLIGHTED_PIN, modelOf, PARTS_WITH_GHOST } from './models.test-helper.js';
import { DARK, LIGHT } from './theme.js';

/** @import { MeshBasicMaterial, MeshStandardMaterial } from 'three' */
/** @import { SceneModel, Shape } from './types.js' */

/** @returns {Promise<SceneModel>} */
async function partsScene(source = PARTS_WITH_GHOST) {
  const scene = await sceneOf(await modelOf(source), new GLTFLoader(), LIGHT);
  if (!scene) throw new Error('no scene');
  return scene;
}

/**
 * The highlighted pin's shape of `scene`.
 * @param {SceneModel} scene
 */
function pinOf(scene) {
  const pin = scene.shapes.find((shape) => shape.part === 'pin');
  if (!pin?.seenThrough) throw new Error('no highlighted pin');
  return { pin, copy: pin.seenThrough };
}

/** @param {Shape} shape */
const materialOf = (shape) => /** @type {MeshStandardMaterial} */ (shape.mesh.material);

describe('applyRenderMode', () => {
  it('draws solids as they are, see-through in x-ray, and only their edges in a wireframe', async () => {
    const scene = await partsScene();
    const plate = scene.shapes.find((shape) => shape.part === 'plate');
    const ghost = scene.shapes.find((shape) => shape.ghost);
    if (!plate || !ghost) throw new Error('no plate or ghost');
    applyRenderMode(scene, 'xray', true);
    expect(materialOf(plate)).toMatchObject({
      transparent: true,
      opacity: XRAY_OPACITY,
      depthWrite: false,
    });
    applyRenderMode(scene, 'wireframe', true);
    expect(materialOf(plate).visible).toBe(false);
    expect(plate.edges?.visible).toBe(true);
    applyRenderMode(scene, 'solid', true);
    expect(materialOf(plate)).toMatchObject({
      visible: true,
      transparent: false,
      opacity: 1,
      depthWrite: true,
    });
    // A ghost keeps its own look
    expect(materialOf(ghost)).toMatchObject({ visible: true, opacity: GHOST_OPACITY });
  });

  it('sees a highlight through what hides it only as solids are: x-ray sees all through', async () => {
    const scene = await partsScene(HIGHLIGHTED_PIN);
    const { copy } = pinOf(scene);
    const seen = /** @type {const} */ (['solid', 'xray', 'wireframe']).map((mode) => {
      applyRenderMode(scene, mode, true);
      return copy.visible;
    });
    expect(seen).toEqual([true, false, false]);
  });

  it("draws the edges or not, as asked, but always a wireframe's, which is nothing else", async () => {
    const scene = await partsScene();
    const plate = scene.shapes.find((shape) => shape.part === 'plate');
    if (!plate) throw new Error('no plate');
    applyRenderMode(scene, 'solid', false);
    expect(plate.edges?.visible).toBe(false);
    applyRenderMode(scene, 'xray', false);
    expect(plate.edges?.visible).toBe(false);
    applyRenderMode(scene, 'wireframe', false);
    expect(plate.edges?.visible).toBe(true);
    applyRenderMode(scene, 'solid', true);
    expect(plate.edges?.visible).toBe(true);
  });
});

describe('applySelection', () => {
  it("tints every copy of the part and draws their edges in the selection's colour, and undoes it", async () => {
    const scene = await partsScene();
    const selectionEdges = new LineBasicMaterial();
    const bolts = scene.shapes.filter((shape) => shape.part === 'bolt');
    const plate = scene.shapes.find((shape) => shape.part === 'plate');
    if (!plate) throw new Error('no plate');
    applySelection(scene, 'bolt', '#2f80ed', selectionEdges);
    const tinted = bolts[0].color.clone().lerp(new Color('#2f80ed'), SELECTION_TINT);
    for (const bolt of bolts) {
      expect(materialOf(bolt).color.equals(tinted)).toBe(true);
      expect(bolt.edges?.material).toBe(selectionEdges);
    }
    expect(materialOf(plate).color.equals(plate.color)).toBe(true);
    expect(plate.edges?.material).toBe(scene.edgeMaterial);
    applySelection(scene, null, '#2f80ed', selectionEdges);
    expect(materialOf(bolts[0]).color.equals(bolts[0].color)).toBe(true);
    expect(bolts[0].edges?.material).toBe(scene.edgeMaterial);
  });
});

describe('applyTheme', () => {
  it("gives the edges, a ghost and a highlight the theme's colours, which the selection tints", async () => {
    const ghostly = await partsScene();
    applyTheme(ghostly, DARK);
    expect(ghostly.edgeMaterial.color.getHexString()).toBe(DARK.edges.slice(1));
    const ghost = ghostly.shapes.find((shape) => shape.ghost);
    expect(ghost?.color.getHexString()).toBe(DARK.ghost.slice(1));

    const scene = await partsScene(HIGHLIGHTED_PIN);
    const { pin, copy } = pinOf(scene);
    applyTheme(scene, DARK);
    expect(pin.color.getHexString()).toBe(DARK.highlight.slice(1));
    expect(/** @type {MeshBasicMaterial} */ (copy.material).color.getHexString()).toBe(
      DARK.highlight.slice(1),
    );
    applySelection(scene, null, DARK.selection, new LineBasicMaterial());
    expect(materialOf(pin).color.getHexString()).toBe(DARK.highlight.slice(1));
  });
});
