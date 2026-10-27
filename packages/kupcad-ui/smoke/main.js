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
  async pixel(x, y) {
    const bitmap = await createImageBitmap(await viewer.screenshot());
    const context = /** @type {OffscreenCanvasRenderingContext2D} */ (
      new OffscreenCanvas(bitmap.width, bitmap.height).getContext('2d')
    );
    context.drawImage(bitmap, 0, 0);
    const { data } = context.getImageData(
      Math.floor(x * bitmap.width),
      Math.floor(y * bitmap.height),
      1,
      1,
    );
    return [data[0], data[1], data[2]];
  },
};
window.ready = true;
