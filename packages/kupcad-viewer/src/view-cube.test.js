import { Vector3 } from 'three';
import { afterEach, expect, it } from 'vitest';
import { modelOf } from './models.test-helper.js';
import { stubRenderer } from './testing.js';
import { ViewCube } from './view-cube.js';
import { Viewer } from './viewer.js';

/** @import { View } from './types.js' */

/** The cube's canvas, laid out at this many CSS pixels a side (jsdom lays nothing out). */
const SIDE = 96;
const MIDDLE = SIDE / 2;

/** @type {(() => void)[]} */
const disposals = [];
afterEach(() => {
  for (const dispose of disposals.splice(0)) dispose();
});

/** A viewer showing a block, whose camera moves at once, and a view cube following it. */
async function cubeOn() {
  const { renderer } = stubRenderer();
  const viewer = new Viewer(document.createElement('canvas'), { renderer, motionMs: 0 });
  await viewer.setModel(await modelOf('cube(20, center: true)'));
  const canvas = document.createElement('canvas');
  Object.defineProperty(canvas, 'clientWidth', { value: SIDE });
  Object.defineProperty(canvas, 'clientHeight', { value: SIDE });
  const cube = new ViewCube(canvas, viewer, { renderer });
  disposals.push(
    () => cube.dispose(),
    () => viewer.dispose(),
  );
  /** @param {number} x @param {number} y */
  const click = (x, y) => {
    for (const type of ['pointerdown', 'pointerup']) {
      canvas.dispatchEvent(
        Object.assign(new Event(type), { offsetX: x, offsetY: y, isPrimary: true, button: 0 }),
      );
    }
  };
  return { viewer, cube, canvas, click };
}

it('is turned as the camera is: its corner toward the iso view, its top toward the top', async () => {
  const { viewer, cube } = await cubeOn();
  expect(cube.directionAt(MIDDLE, MIDDLE)).toEqual([1, -1, 1]);
  viewer.setCamera({ view: 'top' });
  expect(cube.directionAt(MIDDLE, MIDDLE)).toEqual([0, 0, 1]);
  viewer.setCamera({ view: 'front' });
  expect(cube.directionAt(MIDDLE, MIDDLE)).toEqual([0, -1, 0]);
  // Off the cube, nothing
  expect(cube.directionAt(2, 2)).toBeNull();
});

it('looks from the face, edge or corner clicked', async () => {
  const { viewer, canvas, click } = await cubeOn();
  /** @type {(View | null)[]} */
  const views = [];
  viewer.addEventListener('view', (event) => {
    views.push(/** @type {CustomEvent<{ view: View | null }>} */ (event).detail.view);
  });
  viewer.setCamera({ view: 'top' });
  // From the top, the front edge is the cube's lower one, below its middle
  click(MIDDLE, MIDDLE + 20);
  expect(views).toEqual(['top', null]);
  // The camera looks from the front and the top alike: from (0, -1, 1)
  const from = new Vector3(0, 0, 1).applyQuaternion(viewer.orientation);
  expect(from.dot(new Vector3(0, -1, 1).normalize())).toBeCloseTo(1, 6);
  // A drag is no click
  for (const [type, x] of /** @type {const} */ ([
    ['pointerdown', MIDDLE],
    ['pointerup', MIDDLE + 30],
  ])) {
    canvas.dispatchEvent(
      Object.assign(new Event(type), { offsetX: x, offsetY: MIDDLE, isPrimary: true, button: 0 }),
    );
  }
  expect(views).toEqual(['top', null]);
});

it('lights up the part under the pointer, and nothing once it leaves', async () => {
  const { canvas } = await cubeOn();
  canvas.dispatchEvent(
    Object.assign(new Event('pointermove'), { offsetX: MIDDLE, offsetY: MIDDLE }),
  );
  expect(canvas.style.cursor).toBe('pointer');
  canvas.dispatchEvent(new Event('pointerleave'));
  expect(canvas.style.cursor).toBe('');
});
