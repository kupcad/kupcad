// The smoke test's page: a viewer drawing with WebGL what the core, in this page, makes of a
// script, its view cube, and the hooks the test drives them by (window.smoke), once it is ready.
// The camera moves at once, so what the test reads is where it went.

import { createKupcad } from '@kupcad/wasm';
import { LIGHT, ViewCube, Viewer } from '../src/viewer/index.js';
import { BACKGROUND, CAP } from './colors.js';

const canvas = /** @type {HTMLCanvasElement} */ (document.querySelector('#viewer'));
const theme = { ...LIGHT, background: BACKGROUND, cap: CAP };
const viewer = new Viewer(canvas, { theme, environment: 'none', motionMs: 0 });
// The test reads the model's pixels, where the axes would cross the origin
viewer.setAxes(false);
const cube = new ViewCube(
  /** @type {HTMLCanvasElement} */ (document.querySelector('#cube')),
  viewer,
  {
    theme,
  },
);
cube.resize();
const core = await createKupcad({ log: () => {} });

window.smoke = {
  async show(source) {
    const { header, model } = await core.preview(source);
    if (header.error) throw new Error(header.error.message);
    await viewer.setModel(model);
  },
  setCamera: (camera) => viewer.setCamera(camera),
  view: () => viewer.view,
  setSection: (section) => viewer.setSection(section),
  setEnvironment: (environment) => viewer.setEnvironment(environment),
  async pixel(x, y) {
    const [colour] = await pixels(x, y, x, y);
    return colour;
  },
  pixels,
};

/**
 * Every colour drawn in the rectangle from (x0, y0) to (x1, y1), fractions of the canvas from
 * its top left, row by row.
 * @param {number} x0
 * @param {number} y0
 * @param {number} x1
 * @param {number} y1
 * @returns {Promise<[number, number, number][]>}
 */
async function pixels(x0, y0, x1, y1) {
  const bitmap = await createImageBitmap(await viewer.screenshot());
  const context = /** @type {OffscreenCanvasRenderingContext2D} */ (
    new OffscreenCanvas(bitmap.width, bitmap.height).getContext('2d')
  );
  context.drawImage(bitmap, 0, 0);
  const left = Math.floor(x0 * bitmap.width);
  const top = Math.floor(y0 * bitmap.height);
  const width = Math.max(Math.floor(x1 * bitmap.width) - left, 1);
  const height = Math.max(Math.floor(y1 * bitmap.height) - top, 1);
  const { data } = context.getImageData(left, top, width, height);
  /** @type {[number, number, number][]} */
  const colours = [];
  for (let at = 0; at < data.length; at += 4) colours.push([data[at], data[at + 1], data[at + 2]]);
  return colours;
}
window.ready = true;
