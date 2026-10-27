import {
  Color,
  EdgesGeometry,
  GreaterDepth,
  LineBasicMaterial,
  LineSegments,
  MeshBasicMaterial,
  MeshStandardMaterial,
  PlaneGeometry,
  Vector3,
} from 'three';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { COPY_GLOW, FACE_GLOW } from './hover-mark.js';
import { GHOST_OPACITY } from './model.js';
import { dracoModelOf, HIGHLIGHTED_PIN, modelOf, PARTS_WITH_GHOST } from './models.test-helper.js';
import { stubRenderer } from './testing.js';
import { DARK, LIGHT } from './theme.js';
import { Viewer, ViewerError } from './viewer.js';

/** @import { Camera, Mesh, Object3D, OrthographicCamera, PerspectiveCamera, Scene } from 'three' */
/** @import { Section, View, ViewerOptions } from './types.js' */

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
 * The colours of the shapes' edges in `scene` (the lines along a mesh's edges), each once, as
 * `#rrggbb`.
 * @param {Scene} scene
 * @returns {string[]}
 */
function edgeColorsOf(scene) {
  /** @type {Set<string>} */
  const colors = new Set();
  scene.traverse((object) => {
    if (object instanceof LineSegments && object.geometry instanceof EdgesGeometry) {
      colors.add(`#${/** @type {LineBasicMaterial} */ (object.material).color.getHexString()}`);
    }
  });
  return [...colors];
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

/**
 * How many X axes (red lines) `scene` draws.
 * @param {Scene} scene
 */
function xAxes(scene) {
  let found = 0;
  scene.traverse((object) => {
    const material = /** @type {Partial<Mesh>} */ (object).material;
    if (material instanceof LineBasicMaterial && material.color.getHexString() === 'e5484d') {
      found += 1;
    }
  });
  return found;
}

/**
 * Turns the wheel over `canvas`: whether the page was kept from scrolling.
 * @param {HTMLCanvasElement} canvas
 * @param {WheelEventInit} init
 */
function wheelOn(canvas, init) {
  const event = new WheelEvent('wheel', { cancelable: true, ...init });
  canvas.dispatchEvent(event);
  return event.defaultPrevented;
}

/**
 * The first solid's mesh in `scene`, and the hover's glows under it.
 * @param {Scene} scene
 */
function blockIn(scene) {
  /** @type {Mesh[]} */
  const meshes = [];
  scene.traverse((object) => {
    if (/** @type {Partial<Mesh>} */ (object).material instanceof MeshStandardMaterial) {
      meshes.push(/** @type {Mesh} */ (object));
    }
  });
  const [mesh] = meshes;
  /** @param {number} opacity */
  const glowOf = (opacity) =>
    /** @type {Mesh | undefined} */ (
      mesh.children.find(
        (child) =>
          /** @type {MeshBasicMaterial} */ (/** @type {Mesh} */ (child).material)?.opacity ===
          opacity,
      )
    );
  return { mesh, copy: glowOf(COPY_GLOW), face: glowOf(FACE_GLOW) };
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

  it("cuts a highlight's copy, seen through what hides it, at the section too", async () => {
    const { viewer, drawn } = viewerOn();
    await viewer.setModel(await modelOf(HIGHLIGHTED_PIN));
    viewer.setSection({ axis: 'z', offset: 5 });
    /** @type {MeshBasicMaterial[]} */
    const copies = [];
    (await sceneDrawn(drawn)).traverse((object) => {
      const { material } = /** @type {Partial<Mesh>} */ (object);
      if (material instanceof MeshBasicMaterial && material.depthFunc === GreaterDepth) {
        copies.push(material);
      }
    });
    expect(copies).toHaveLength(1);
    expect(copies[0].clippingPlanes).toHaveLength(1);
    viewer.setSection(null);
    expect(copies[0].clippingPlanes).toBeNull();
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

  it('gives where its camera stands, and stands it there again, through either camera', async () => {
    const { viewer, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    viewer.lookFrom([1, -1, 1]);
    viewer.zoom(2);
    await nextFrame();
    const camera = () => /** @type {Camera} */ (drawn.camera);
    const left = /** @type {import('./types.js').CameraState} */ (
      JSON.parse(JSON.stringify(viewer.cameraState()))
    );
    const position = camera().position.clone();
    expect(left.view).toBe('iso');
    viewer.setCamera({ view: 'top' });
    viewer.restoreCamera(left);
    await nextFrame();
    expect(camera().position.distanceTo(position)).toBeCloseTo(0, 6);
    expect(viewer.view).toBe('iso');
    // Through the orthographic camera, as much seen at what it looks at
    viewer.setCamera({ projection: 'orthographic' });
    viewer.restoreCamera(left);
    await nextFrame();
    const orthographic = /** @type {OrthographicCamera} */ (drawn.camera);
    expect(orthographic.top / orthographic.zoom).toBeCloseTo(left.halfHeight, 6);
    // And its state through the perspective camera again: where it stood at first
    const fromOrthographic = viewer.cameraState();
    viewer.setCamera({ projection: 'perspective' });
    viewer.restoreCamera(fromOrthographic);
    await nextFrame();
    expect(camera().position.distanceTo(position)).toBeCloseTo(0, 6);
    // A named view it no longer looks from is none
    viewer.restoreCamera({ ...left, view: 'top' });
    expect(viewer.view).toBeNull();
  });

  it('fits at once when asked to, a move over a moment otherwise', async () => {
    const { viewer, drawn } = viewerOn({ motionMs: 1000 });
    await viewer.setModel(await modelOf(BLOCK));
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    const framed = camera.position.length();
    viewer.zoom(2);
    viewer.fit();
    await nextFrame();
    // A moment in, the move has far to go
    expect(camera.position.length()).toBeLessThan(framed * 0.9);
    viewer.zoom(2);
    viewer.fit({ instant: true });
    await nextFrame();
    expect(camera.position.length()).toBeCloseTo(framed, 6);
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

  it('zooms with the wheel, the controls none, while a button turns the view too', async () => {
    const { viewer, canvas, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    const framed = camera.position.length();
    expect(wheelOn(canvas, { deltaY: -100 })).toBe(true);
    // Its zoom alone: the controls, which zoom with the wheel too, heard none of it
    expect(camera.position.length()).toBeCloseTo(framed * 0.95, 6);
    // While the left button turns the view, and the right one pans; not with the middle one
    // held, which is the wheel pressed
    for (const [button, buttons] of [
      [0, 1],
      [2, 2],
    ]) {
      const at = { pointerId: 1, pointerType: 'mouse', button, clientX: 100, clientY: 100 };
      canvas.dispatchEvent(Object.assign(new Event('pointerdown'), at));
      const before = camera.position.length();
      wheelOn(canvas, { deltaY: 100, buttons });
      expect(camera.position.length()).toBeCloseTo(before / 0.95, 6);
      document.dispatchEvent(Object.assign(new Event('pointerup'), at));
    }
    const before = camera.position.length();
    expect(wheelOn(canvas, { deltaY: 100, buttons: 4 })).toBe(true);
    expect(camera.position.length()).toBe(before);
    // A pinch is the wheel with Ctrl, which zooms ten times as fast
    wheelOn(canvas, { deltaY: -10, ctrlKey: true });
    expect(camera.position.length()).toBeCloseTo(before * 0.95, 6);
  });

  it('pans with Shift and the wheel: the model moves as a page would scroll, in either camera', async () => {
    const { viewer, canvas, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    for (const projection of /** @type {const} */ (['perspective', 'orthographic'])) {
      viewer.setCamera({ projection, view: 'iso' });
      await nextFrame();
      const camera = /** @type {Camera} */ (drawn.camera);
      wheelOn(canvas, { deltaX: 100, deltaY: -50, shiftKey: true });
      // The block's centre, the origin, was the canvas's: it went left and down
      camera.updateMatrixWorld();
      const seen = new Vector3().project(camera);
      expect((seen.x + 1) * (WIDTH / 2)).toBeCloseTo(WIDTH / 2 - 100, 3);
      expect((1 - seen.y) * (HEIGHT / 2)).toBeCloseTo(HEIGHT / 2 + 50, 3);
      expect(viewer.view).toBe('iso');
    }
  });

  it('turns the view with Cmd and the wheel, as a drag the other way would', async () => {
    const { viewer, canvas, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    // jsdom lays nothing out: the controls turn by the canvas's height
    Object.defineProperty(canvas, 'clientHeight', { value: HEIGHT });
    /** @type {(View | null)[]} */
    const views = [];
    viewer.addEventListener('view', (event) => {
      views.push(/** @type {CustomEvent<{ view: View | null }>} */ (event).detail.view);
    });
    await nextFrame();
    const camera = /** @type {Camera} */ (drawn.camera);
    wheelOn(canvas, { deltaX: 80, deltaY: 40, metaKey: true });
    const turned = camera.position.clone();
    expect(views).toEqual([null]);
    viewer.lookFrom([1, -1, 1]);
    const at = { pointerId: 1, pointerType: 'mouse', button: 0, clientX: 300, clientY: 300 };
    canvas.dispatchEvent(Object.assign(new Event('pointerdown'), at));
    const to = { ...at, clientX: 300 - 80, clientY: 300 - 40 };
    document.dispatchEvent(Object.assign(new Event('pointermove'), to));
    document.dispatchEvent(Object.assign(new Event('pointerup'), to));
    expect(camera.position.distanceTo(turned)).toBeCloseTo(0, 6);
  });

  it('moves the section with Option and the wheel, from the top when none is on, and says so', async () => {
    const { viewer, canvas } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    /** @type {(Section | null)[]} */
    const said = [];
    viewer.addEventListener('section', (event) => {
      said.push(/** @type {CustomEvent<{ section: Section }>} */ (event).detail.section);
    });
    // The block is 20 mm high: 200 of the 2000 pixels across it are 2 mm down from its top
    wheelOn(canvas, { deltaY: 200, altKey: true });
    expect(viewer.section?.axis).toBe('z');
    expect(viewer.section?.offset).toBeCloseTo(8, 4);
    expect(said).toEqual([viewer.section]);
    // Along the section's axis, flipped as it is, and no further than the model
    viewer.setSection({ axis: 'x', offset: 0, flip: true });
    wheelOn(canvas, { deltaY: -100_000, altKey: true });
    expect(viewer.section).toEqual({ axis: 'x', offset: viewer.bounds?.max[0], flip: true });
    expect(said).toHaveLength(2);
    // A drawing isn't cut
    await viewer.setModel(await modelOf('square(10)'));
    viewer.setSection(null);
    wheelOn(canvas, { deltaY: 200, altKey: true });
    expect(viewer.section).toBeNull();
    expect(said).toHaveLength(2);
  });

  it('says what is under a point: the part, and the face, flat or curved, its area and way', async () => {
    const { viewer } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    viewer.setCamera({ view: 'top' });
    const top = viewer.hoverAt(WIDTH / 2, HEIGHT / 2);
    expect(top?.part).toBe('block');
    expect(top?.face).toMatchObject({ flat: true, facing: '+Z (top)' });
    expect(top?.face?.area).toBeCloseTo(400, 6);
    // A rod's side from the front, its facets meeting at 7.5°: one curved face, as the edges
    // bound it (a coarser one's facets, past the edges' 20°, are faces of their own)
    await viewer.setModel(
      await modelOf('cylinder(r: 5, h: 10, center: true, segments: 48).named("rod")'),
    );
    viewer.setCamera({ view: 'front' });
    const rod = viewer.hoverAt(WIDTH / 2, HEIGHT / 2);
    expect(rod?.part).toBe('rod');
    expect(rod?.face?.flat).toBe(false);
    expect(rod?.face?.facing).toBeNull();
    const side = 2 * Math.PI * 5 * 10;
    expect(rod?.face?.area).toBeGreaterThan(0.85 * side);
    expect(rod?.face?.area).toBeLessThan(side);
    expect(viewer.hoverAt(2, 2)).toBeNull();
  });

  it('says what the pointer is over as it moves, a frame at most, and nothing while it drags', async () => {
    const { viewer, canvas } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    /** @type {({ part: string | null } | null)[]} */
    const said = [];
    viewer.addEventListener('hover', (event) => {
      said.push(/** @type {CustomEvent<{ part: string | null } | null>} */ (event).detail);
    });
    /** @param {string} type @param {number} x @param {number} [buttons] */
    const pointer = (type, x, buttons = 0) => {
      canvas.dispatchEvent(
        Object.assign(new Event(type), { offsetX: x, offsetY: HEIGHT / 2, buttons }),
      );
    };
    pointer('pointermove', WIDTH / 2 - 2);
    pointer('pointermove', WIDTH / 2);
    await nextFrame();
    expect(said).toHaveLength(1);
    expect(said[0]).toMatchObject({ part: 'block', x: WIDTH / 2, y: HEIGHT / 2 });
    // Dragging the camera, nothing is under it
    pointer('pointermove', WIDTH / 2, 1);
    await nextFrame();
    expect(said.at(-1)).toBeNull();
    pointer('pointermove', WIDTH / 2);
    await nextFrame();
    canvas.dispatchEvent(new Event('pointerleave'));
    await nextFrame();
    expect(said.at(-1)).toBeNull();
    // Off the model, once said, nothing more
    const count = said.length;
    pointer('pointermove', 2);
    await nextFrame();
    expect(said).toHaveLength(count);
  });

  it('marks what the pointer is over: its copy and its face glow, nothing once off it', async () => {
    const { viewer, canvas, drawn } = viewerOn();
    await viewer.setModel(await modelOf(BLOCK));
    viewer.setCamera({ view: 'top' });
    /** @param {number} x @param {number} [buttons] */
    const pointAt = async (x, buttons = 0) => {
      canvas.dispatchEvent(
        Object.assign(new Event('pointermove'), { offsetX: x, offsetY: HEIGHT / 2, buttons }),
      );
      return sceneDrawn(drawn);
    };
    expect(blockIn(await sceneDrawn(drawn)).copy).toBeUndefined();
    const over = blockIn(await pointAt(WIDTH / 2));
    expect(over.copy).toBeDefined();
    // The top face, seen from the top: two triangles, at the top of the block
    const face = /** @type {Mesh} */ (over.face);
    const position = face.geometry.getAttribute('position');
    expect(position.count).toBe(6);
    for (let i = 0; i < position.count; i++) {
      const corner = new Vector3().fromBufferAttribute(position, i);
      expect(corner.applyMatrix4(over.mesh.matrixWorld).z).toBeCloseTo(10, 4);
    }
    // In the selection's colour, cut at a section as the model is
    const glowing = /** @type {MeshBasicMaterial} */ (face.material);
    expect(glowing.color.getHexString()).toBe(LIGHT.selection.slice(1));
    viewer.setTheme(DARK);
    expect(glowing.color.getHexString()).toBe(DARK.selection.slice(1));
    viewer.setSection({ axis: 'z', offset: 5 });
    expect(glowing.clippingPlanes).toHaveLength(1);
    viewer.setSection(null);
    // Off the model, while dragging, and once a model replaced it: nothing marked
    expect(blockIn(await pointAt(2)).copy).toBeUndefined();
    await pointAt(WIDTH / 2);
    expect(blockIn(await pointAt(WIDTH / 2, 1)).copy).toBeUndefined();
    await pointAt(WIDTH / 2);
    await viewer.setModel(await modelOf(BLOCK));
    expect(blockIn(await sceneDrawn(drawn)).copy).toBeUndefined();
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

  it("draws a wireframe's edges, on the background, in its theme's wire colour", async () => {
    const { viewer, drawn } = viewerOn({ theme: DARK, environment: 'none' });
    viewer.setAxes(false);
    await viewer.setModel(await modelOf('cube(2)'));
    expect(edgeColorsOf(await sceneDrawn(drawn))).toEqual([DARK.edges]);
    viewer.setRenderMode('wireframe');
    expect(edgeColorsOf(await sceneDrawn(drawn))).toEqual([DARK.wire]);
    // A theme set in a wireframe keeps to it
    viewer.setTheme(LIGHT);
    expect(edgeColorsOf(await sceneDrawn(drawn))).toEqual([LIGHT.wire]);
    viewer.setRenderMode('solid');
    expect(edgeColorsOf(await sceneDrawn(drawn))).toEqual([LIGHT.edges]);
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
    // The axes through the origin, drawn until they are asked away
    expect(viewer.axes).toBe(true);
    expect(xAxes(await sceneDrawn(drawn))).toBe(1);
    viewer.setAxes(false);
    expect(viewer.axes).toBe(false);
    expect(xAxes(await sceneDrawn(drawn))).toBe(0);
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
