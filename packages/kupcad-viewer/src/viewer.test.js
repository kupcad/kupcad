import { Color, PlaneGeometry } from 'three';
import { describe, expect, it, vi } from 'vitest';
import { dracoModelOf, modelOf, PARTS_WITH_GHOST } from './models.test-helper.js';
import { stubRenderer } from './testing.js';
import { DARK, LIGHT } from './theme.js';
import { Viewer, ViewerError } from './viewer.js';

/** @import { Camera, Mesh, Object3D, Scene } from 'three' */
/** @import { ViewerOptions } from './types.js' */

const WIDTH = 800;
const HEIGHT = 600;

/** The Draco decoders made, and how many were disposed: jsdom runs no decoder of its own. */
const draco = vi.hoisted(() => ({ made: 0, disposed: 0 }));
vi.mock('three/addons/loaders/DRACOLoader.js', () => ({
  DRACOLoader: class {
    constructor() {
      draco.made += 1;
    }
    setDecoderPath() {
      return this;
    }
    dispose() {
      draco.disposed += 1;
    }
  },
}));

/**
 * A viewer on a canvas of WIDTH × HEIGHT, drawing with a stand-in for WebGL.
 * @param {ViewerOptions} [options]
 */
function viewerOn(options = {}) {
  const { renderer, drawn } = stubRenderer();
  const canvas = document.createElement('canvas');
  const viewer = new Viewer(canvas, { ...options, renderer });
  viewer.resize(WIDTH, HEIGHT);
  return { viewer, canvas, drawn };
}

/**
 * What a viewer drew last, once the next frame is drawn.
 * @param {{ scene: Object3D | null }} drawn
 */
async function sceneDrawn(drawn) {
  await nextFrame();
  return /** @type {Scene} */ (drawn.scene);
}

const nextFrame = () => new Promise((resolve) => requestAnimationFrame(resolve));

/**
 * The planes `width` wide in `scene`: a build plate's surface.
 * @param {Scene} scene
 * @param {number} width
 * @returns {PlaneGeometry[]}
 */
function planesOf(scene, width) {
  /** @type {PlaneGeometry[]} */
  const found = [];
  scene.traverse((object) => {
    const { geometry } = /** @type {Partial<Mesh>} */ (object);
    if (geometry instanceof PlaneGeometry && geometry.parameters.width === width) {
      found.push(geometry);
    }
  });
  return found;
}

const BLOCK = 'cube(20, center: true).named("block")';

describe('Viewer', () => {
  it('frames the first model, draws once a frame, and picks its parts', async () => {
    const { viewer, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    await nextFrame();
    expect(drawn.renders).toBe(1);
    // The camera looks at the model from the iso view: its centre is the canvas's
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('block');
    expect(viewer.partAt(5, 5)).toBeNull();
  });

  it('selects a part on a click, and says so; a drag is no click', async () => {
    const { viewer, canvas } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    /** @type {(string | null)[]} */
    const said = [];
    viewer.addEventListener('select', (event) => {
      said.push(/** @type {CustomEvent<{ part: string | null }>} */ (event).detail.part);
    });
    /** @param {string} type @param {number} x @param {number} y */
    const pointer = (type, x, y) => {
      canvas.dispatchEvent(Object.assign(new Event(type), { offsetX: x, offsetY: y }));
    };
    pointer('pointerdown', WIDTH / 2, HEIGHT / 2);
    pointer('pointerup', WIDTH / 2 + 1, HEIGHT / 2);
    expect(said).toEqual(['block']);
    expect(viewer.selected).toBe('block');
    pointer('pointerdown', 5, 5);
    pointer('pointerup', 60, 60);
    expect(said).toEqual(['block']);
    pointer('pointerdown', 5, 5);
    pointer('pointerup', 5, 5);
    expect(said).toEqual(['block', null]);
  });

  it('cuts at a section in a wireframe too, which has no cap', async () => {
    const { viewer } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    viewer.setCamera({ view: 'top' });
    viewer.setRenderMode('wireframe');
    viewer.setSection({ axis: 'z', offset: -15 });
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBeNull();
  });

  it("doesn't cut a drawing, nor miss its parts, while a section is on", async () => {
    const { viewer } = viewerOn();
    viewer.setSection({ axis: 'x', offset: 0 });
    await viewer.setModel(
      await modelOf('square(10, center: true).translate(x: -20).named("plate")'),
    );
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('plate');
  });

  it('cuts at a section, and picks nothing cut away', async () => {
    const { viewer } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    viewer.setCamera({ view: 'top' });
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('block');
    // Everything above z = -15 is cut away: the whole cube
    viewer.setSection({ axis: 'z', offset: -15 });
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBeNull();
    // Flipped, what is below is: the cube stays
    viewer.setSection({ axis: 'z', offset: -15, flip: true });
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('block');
    viewer.setSection({ axis: 'z', offset: 0 });
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('block');
    expect(viewer.section).toEqual({ axis: 'z', offset: 0 });
    viewer.setSection(null);
    expect(viewer.section).toBeNull();
  });

  it("gives the model's bounds in the script's coordinates, none without a model", async () => {
    const { viewer } = viewerOn();
    expect(viewer.bounds).toBeNull();
    await viewer.setModel(await modelOf('cube([20, 10, 2]).translate(z: 5)'));
    const bounds = viewer.bounds;
    expect(bounds?.min.map((v) => Math.round(v * 1000) / 1000 + 0)).toEqual([0, 0, 5]);
    expect(bounds?.max.map((v) => Math.round(v * 1000) / 1000 + 0)).toEqual([20, 10, 7]);
  });

  it('shows a drawing from the top, orthographic', async () => {
    const { viewer } = viewerOn();
    await viewer.setModel(await modelOf('square(10, center: true).named("plate")'));
    expect(viewer.projection).toBe('orthographic');
    expect(viewer.view).toBe('top');
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('plate');
  });

  it('keeps the camera for a model that follows, and the selection while its part is there', async () => {
    const { viewer } = viewerOn();
    /** @type {(string | null)[]} */
    const said = [];
    viewer.addEventListener('select', (event) => {
      said.push(/** @type {CustomEvent<{ part: string | null }>} */ (event).detail.part);
    });
    await viewer.setModel(await modelOf(PARTS_WITH_GHOST));
    viewer.setCamera({ view: 'front', projection: 'orthographic' });
    viewer.select('bolt');
    await viewer.setModel(await modelOf(PARTS_WITH_GHOST.replace('r: 2', 'r: 3')));
    expect(viewer.view).toBe('front');
    expect(viewer.projection).toBe('orthographic');
    expect(viewer.selected).toBe('bolt');
    expect(said).toEqual([]);
    // Its part gone, the selection goes, and the host is told
    await viewer.setModel(await modelOf('cube(1).named("other")'));
    expect(viewer.selected).toBeNull();
    expect(said).toEqual([null]);
  });

  it('keeps the camera through a model of nothing, as one that failed shows', async () => {
    const { viewer, drawn } = viewerOn();
    await viewer.setModel(await modelOf('cube(10)'));
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    const framed = camera.position.clone();
    await viewer.setModel(null);
    await viewer.setModel({ kind: 'none' });
    await viewer.setModel(await modelOf('cube(40)'));
    await nextFrame();
    expect(camera.position.toArray()).toEqual(framed.toArray());
  });

  it('looks through either camera at the same model', async () => {
    const { viewer } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    viewer.setCamera({ projection: 'orthographic' });
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('block');
    viewer.setCamera({ projection: 'perspective' });
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('block');
  });

  it('shows only the last of models asked for one after another', async () => {
    const { viewer } = viewerOn();
    const [first, second] = await Promise.all([
      modelOf('cube(1).named("first")'),
      modelOf('cube(1).named("second")'),
    ]);
    await Promise.all([viewer.setModel(first), viewer.setModel(second)]);
    viewer.fit();
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('second');
  });

  it("refuses a Draco-compressed model without the decoder's files", async () => {
    const { viewer } = viewerOn();
    await expect(viewer.setModel(await dracoModelOf('cube(2)'))).rejects.toBeInstanceOf(
      ViewerError,
    );
  });

  it("makes the Draco decoder with the decoder's files given, once, and frees it disposed", async () => {
    const { viewer } = viewerOn({ dracoDecoderPath: '/draco/' });
    const before = { ...draco };
    await viewer.setModel(await modelOf('cube(1)'));
    await viewer.setModel(await modelOf('cube(2)'));
    expect(draco.made - before.made).toBe(1);
    viewer.dispose();
    expect(draco.disposed - before.disposed).toBe(1);
  });

  it('says why a screenshot failed when the canvas gives no image', async () => {
    const { viewer, canvas } = viewerOn();
    canvas.toBlob = (callback) => callback(null);
    await expect(viewer.screenshot()).rejects.toBeInstanceOf(ViewerError);
  });

  it("draws in its theme's colours, and stands the model on the environment asked for", async () => {
    const { viewer, drawn } = viewerOn({
      theme: LIGHT,
      environment: 'plate',
      plate: { width: 200, depth: 100 },
    });
    await viewer.setModel(await modelOf('cube(2)'));
    const scene = await sceneDrawn(drawn);
    expect(/** @type {Color} */ (scene.background).getHexString()).toBe(
      new Color(LIGHT.background).getHexString(),
    );
    expect(planesOf(scene, 200).map((plate) => plate.parameters.height)).toEqual([100]);
    viewer.setTheme(DARK);
    viewer.setEnvironment('grid');
    const redrawn = await sceneDrawn(drawn);
    expect(/** @type {Color} */ (redrawn.background).getHexString()).toBe(
      new Color(DARK.background).getHexString(),
    );
    expect(planesOf(redrawn, 200)).toEqual([]);
  });

  it('switches render modes, environments and themes, and stops drawing once disposed', async () => {
    const { viewer, drawn } = viewerOn({ theme: DARK, environment: 'plate' });
    await viewer.setModel(await modelOf('cube(2)'));
    for (const mode of /** @type {const} */ (['xray', 'wireframe', 'solid'])) {
      viewer.setRenderMode(mode);
      expect(viewer.renderMode).toBe(mode);
    }
    viewer.setEnvironment('none');
    expect(viewer.environment).toBe('none');
    await nextFrame();
    viewer.dispose();
    expect(drawn.disposed).toBe(true);
    const before = drawn.renders;
    viewer.setRenderMode('xray');
    await nextFrame();
    expect(drawn.renders).toBe(before);
  });
});
