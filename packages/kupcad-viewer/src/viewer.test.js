import { Color, MeshStandardMaterial, PlaneGeometry, Vector3 } from 'three';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { GHOST_OPACITY } from './model.js';
import { dracoModelOf, modelOf, PARTS_WITH_GHOST } from './models.test-helper.js';
import { stubRenderer } from './testing.js';
import { DARK, LIGHT } from './theme.js';
import { Viewer, ViewerError } from './viewer.js';

/** @import { Camera, Mesh, Object3D, OrthographicCamera, PerspectiveCamera, Scene } from 'three' */
/** @import { View, ViewerOptions } from './types.js' */

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
 * A viewer on a canvas of WIDTH × HEIGHT, drawing with a stand-in for WebGL; its camera moves at
 * once unless `options` give it time.
 * @param {ViewerOptions} [options]
 */
function viewerOn(options = {}) {
  const { renderer, drawn } = stubRenderer();
  const canvas = document.createElement('canvas');
  const viewer = new Viewer(canvas, { motionMs: 0, ...options, renderer });
  made.push(viewer);
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
 * The colours of the ghosts in `scene`, as hex: the meshes seen through at a ghost's opacity.
 * @param {Scene} scene
 * @returns {string[]}
 */
function ghostColorsOf(scene) {
  /** @type {string[]} */
  const colors = [];
  scene.traverse((object) => {
    const material = /** @type {Partial<Mesh>} */ (object).material;
    if (material instanceof MeshStandardMaterial && material.opacity === GHOST_OPACITY) {
      colors.push(material.color.getHexString());
    }
  });
  return colors;
}

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

/**
 * How far in front of the camera the next frame is drawn from each corner of the 256 mm plate
 * lies (behind it, below 0), and the camera.
 * @param {{ scene: Object3D | null, camera: Camera | null }} drawn
 */
async function plateDepths(drawn) {
  const scene = await sceneDrawn(drawn);
  const camera = /** @type {OrthographicCamera | PerspectiveCamera} */ (drawn.camera);
  scene.updateMatrixWorld(true);
  camera.updateMatrixWorld();
  const [plate] = planesOf(scene, 256);
  const position = plate.getAttribute('position');
  /** @type {number[]} */
  const depths = [];
  for (let i = 0; i < position.count; i++) {
    const corner = new Vector3().fromBufferAttribute(position, i);
    depths.push(-corner.applyMatrix4(camera.matrixWorldInverse).z);
  }
  return { camera, depths };
}

const BLOCK = 'cube(20, center: true).named("block")';

/** The viewers a test made: disposed after it, so none of their controls hears the next test's pointer. @type {Viewer[]} */
const made = [];
afterEach(() => {
  for (const viewer of made.splice(0)) viewer.dispose();
});

describe('Viewer', () => {
  it('frames the first model, draws once a frame, and picks its parts', async () => {
    const { viewer, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    // Whatever was asked so far is drawn: the viewer made, then the model shown, in one frame or
    // two, as fast as the core built the model (on CI, a frame came between)
    await nextFrame();
    const before = drawn.renders;
    viewer.setRenderMode('xray');
    viewer.setEnvironment('plate');
    viewer.select('block');
    await nextFrame();
    expect(drawn.renders).toBe(before + 1);
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
    /** @param {string} type @param {number} x @param {number} y @param {number} [button] */
    const pointer = (type, x, y, button = 0) => {
      canvas.dispatchEvent(
        Object.assign(new Event(type), { offsetX: x, offsetY: y, isPrimary: true, button }),
      );
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
    // The right button pans
    pointer('pointerdown', WIDTH / 2, HEIGHT / 2, 2);
    pointer('pointerup', WIDTH / 2, HEIGHT / 2, 2);
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
    expect(viewer.kind).toBeNull();
    await viewer.setModel(await modelOf('square(10, center: true).named("plate")'));
    expect(viewer.kind).toBe('2d');
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

  it('gives a solid after a drawing the camera the last solid was seen with', async () => {
    const { viewer } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    viewer.setCamera({ view: 'front' });
    await viewer.setModel(await modelOf('square(10)'));
    expect([viewer.projection, viewer.view]).toEqual(['orthographic', 'top']);
    await viewer.setModel(await modelOf(BLOCK));
    expect([viewer.projection, viewer.view]).toEqual(['perspective', 'front']);
  });

  it("draws a small model's plate whole, through either camera", async () => {
    const { viewer, drawn } = viewerOn({ environment: 'plate' });
    await viewer.setModel(await modelOf('cube(2)'));
    viewer.setCamera({ projection: 'orthographic' });
    const orthographic = await plateDepths(drawn);
    // An orthographic camera draws what is behind it too
    expect(Math.min(...orthographic.depths)).toBeGreaterThanOrEqual(orthographic.camera.near);
    expect(Math.max(...orthographic.depths)).toBeLessThanOrEqual(orthographic.camera.far);
    viewer.setCamera({ projection: 'perspective' });
    const perspective = await plateDepths(drawn);
    expect(Math.max(...perspective.depths)).toBeLessThanOrEqual(perspective.camera.far);
  });

  it('moves the camera to a view over a moment, and at once when the page asks for less motion', async () => {
    const { viewer, drawn } = viewerOn({ motionMs: 100 });
    await viewer.setModel(await modelOf(BLOCK));
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    // The block is centred on the origin, which the camera looks at
    const looking = () => camera.position.clone().normalize();
    viewer.setCamera({ view: 'top' });
    expect(viewer.view).toBe('top');
    await nextFrame();
    expect(looking().z).toBeLessThan(0.99);
    await vi.waitFor(() => expect(looking().z).toBeGreaterThan(0.999));
    vi.stubGlobal('matchMedia', (/** @type {string} */ query) => ({
      matches: query === '(prefers-reduced-motion: reduce)',
    }));
    try {
      viewer.setCamera({ view: 'front' });
      expect(
        looking()
          .toArray()
          .map((v) => Math.round(v * 1000) / 1000 + 0),
      ).toEqual([0, -1, 0]);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('looks from any direction, a named view by its name, and says when the view changes', async () => {
    const { viewer, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    /** @type {(View | null)[]} */
    const views = [];
    viewer.addEventListener('view', (event) => {
      views.push(/** @type {CustomEvent<{ view: View | null }>} */ (event).detail.view);
    });
    viewer.lookFrom([0, 0, 1]);
    viewer.lookFrom([1, 1, 1]);
    viewer.lookFrom([1, -1, 1]);
    expect(views).toEqual(['top', null, 'iso']);
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    expect(
      camera.position
        .clone()
        .normalize()
        .dot(new Vector3(1, -1, 1).normalize()),
    ).toBeCloseTo(1, 6);
  });

  it('fits the model from where the camera looks, and zooms in and out', async () => {
    const { viewer, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    viewer.lookFrom([1, 1, 1]);
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    const framed = camera.position.clone();
    viewer.zoom(2);
    expect(camera.position.length()).toBeCloseTo(framed.length() / 2, 6);
    viewer.fit();
    // The angle kept, the distance the framing's again
    expect(camera.position.distanceTo(framed)).toBeCloseTo(0, 6);
  });

  it("takes Orca Slicer's keys once it has the focus: views, fit, zoom", async () => {
    const { viewer, canvas, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    expect(canvas.tabIndex).toBe(0);
    /** @param {string} key @param {KeyboardEventInit} [more] */
    const press = (key, more = {}) => {
      const event = new KeyboardEvent('keydown', { key, cancelable: true, ...more });
      canvas.dispatchEvent(event);
      return event.defaultPrevented;
    };
    expect(press('1', { ctrlKey: true })).toBe(true);
    expect(viewer.view).toBe('top');
    expect(press('3')).toBe(true);
    expect(viewer.view).toBe('front');
    expect(press('6', { metaKey: true })).toBe(true);
    expect(viewer.view).toBe('right');
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    const framed = camera.position.length();
    expect(press('i')).toBe(true);
    expect(camera.position.length()).toBeLessThan(framed);
    expect(press('F')).toBe(true);
    expect(camera.position.length()).toBeCloseTo(framed, 6);
    // Left to the page: another key, or one with Alt or Shift
    expect(press('x')).toBe(false);
    expect(press('1', { altKey: true })).toBe(false);
    expect(viewer.view).toBe('right');
  });

  it('is in no named view once turned by hand, and pans with the middle button', async () => {
    const { viewer, canvas, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    // jsdom lays nothing out: the controls turn and pan by the canvas's height
    Object.defineProperty(canvas, 'clientHeight', { value: HEIGHT });
    Object.defineProperty(canvas, 'clientWidth', { value: WIDTH });
    /** @param {number} button @param {number} dx */
    const drag = (button, dx) => {
      const at = { pointerId: 1, pointerType: 'mouse', button, clientX: 100, clientY: 100 };
      canvas.dispatchEvent(Object.assign(new Event('pointerdown'), at));
      document.dispatchEvent(Object.assign(new Event('pointermove'), { ...at, clientX: 100 + dx }));
      document.dispatchEvent(Object.assign(new Event('pointerup'), { ...at, clientX: 100 + dx }));
    };
    /** @type {(View | null)[]} */
    const views = [];
    viewer.addEventListener('view', (event) => {
      views.push(/** @type {CustomEvent<{ view: View | null }>} */ (event).detail.view);
    });
    drag(0, 80);
    expect(viewer.view).toBeNull();
    expect(views).toEqual([null]);
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    const turned = camera.position.clone().normalize();
    // A pan moves the camera across, its direction the same
    const before = camera.position.clone();
    drag(1, 80);
    expect(camera.position.distanceTo(before)).toBeGreaterThan(0.1);
    expect(camera.position.clone().sub(before).dot(turned)).toBeCloseTo(0, 6);
  });

  it('picks the part behind a ghost, which is seen through', async () => {
    const { viewer } = viewerOn();
    await viewer.setModel(
      await modelOf(`cube(30, center: true).translate(x: 20, y: -20, z: 20).ghost\n${BLOCK}`),
    );
    // From the iso view, the ghost stands between the camera and the block's centre
    expect(viewer.partAt(WIDTH / 2, HEIGHT / 2)).toBe('block');
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
    // The first is said not to be shown: a host waits for neither in vain
    expect(await Promise.all([viewer.setModel(first), viewer.setModel(second)])).toEqual([
      false,
      true,
    ]);
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

  it('makes no Draco decoder for a viewer disposed while its module loads', async () => {
    const { viewer } = viewerOn({ dracoDecoderPath: '/draco/' });
    const before = { ...draco };
    const model = await modelOf('cube(1)');
    const loading = viewer.setModel(model);
    viewer.dispose();
    expect(await loading).toBe(false);
    // One made then would be freed by nobody
    expect(draco.made - before.made).toBe(0);
  });

  it('says why a screenshot failed when the canvas gives no image', async () => {
    const { viewer, canvas } = viewerOn();
    canvas.toBlob = (callback) => callback(null);
    await expect(viewer.screenshot()).rejects.toBeInstanceOf(ViewerError);
  });

  it("draws in its theme's colours, and stands the model on the environment asked for", async () => {
    const { viewer, drawn } = viewerOn({ theme: LIGHT, environment: 'none' });
    await viewer.setModel(await modelOf(PARTS_WITH_GHOST));
    viewer.setEnvironment('plate', { width: 200, depth: 100 });
    const scene = await sceneDrawn(drawn);
    expect(ghostColorsOf(scene)).toEqual([new Color(LIGHT.ghost).getHexString()]);
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
    expect(ghostColorsOf(redrawn)).toEqual([new Color(DARK.ghost).getHexString()]);
    expect(planesOf(redrawn, 200)).toEqual([]);
  });

  it('switches render modes, environments and themes, and stops drawing once disposed', async () => {
    const { viewer, drawn } = viewerOn({ theme: DARK, environment: 'plate' });
    await viewer.setModel(await modelOf('cube(2)'));
    for (const mode of /** @type {const} */ (['xray', 'wireframe', 'solid'])) {
      viewer.setRenderMode(mode);
      expect(viewer.renderMode).toBe(mode);
    }
    expect(viewer.edges).toBe(true);
    viewer.setEdges(false);
    expect(viewer.edges).toBe(false);
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
