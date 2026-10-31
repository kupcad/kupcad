// For a host's tests of the viewer and the components. Imported (a Vitest `setupFiles` entry,
// say), it gives jsdom what a browser has and they use: the component watches its canvas's size,
// the camera's controls capture the pointer while it drags, and a screenshot reads the canvas as
// an image, which jsdom draws none of: here an empty PNG. A canvas has no context, as jsdom's has
// none, but quietly (jsdom says "not implemented" when asked). A dialog (the shortcuts') opens and
// closes, which jsdom's element can't. A range of text measures, as an editor beside the viewer
// measures its lines (jsdom lays out nothing: no box). `stubRenderer` draws in place of WebGL.

/** @import { Camera, Object3D } from 'three' */
/** @import { RendererLike } from './types.js' */

globalThis.ResizeObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
};

Range.prototype.getClientRects ??= () => /** @type {DOMRectList} */ (/** @type {unknown} */ ([]));
Range.prototype.getBoundingClientRect ??= () => DOMRect.fromRect();

Element.prototype.setPointerCapture ??= () => {};
Element.prototype.releasePointerCapture ??= () => {};
Element.prototype.hasPointerCapture ??= () => false;

HTMLCanvasElement.prototype.getContext = /** @type {HTMLCanvasElement['getContext']} */ (
  () => null
);

// Shown, a dialog is open; closed, it says so, as a browser's does
HTMLDialogElement.prototype.showModal ??= /** @this {HTMLDialogElement} */ function showModal() {
  this.open = true;
};
HTMLDialogElement.prototype.close ??= /** @this {HTMLDialogElement} */ function close() {
  if (!this.open) return;
  this.open = false;
  this.dispatchEvent(new Event('close'));
};

/** @type {HTMLCanvasElement['toBlob']} */
HTMLCanvasElement.prototype.toBlob = function toBlob(callback, type = 'image/png') {
  callback(new Blob([], { type }));
};

/**
 * A stand-in for WebGL, for a Viewer's `options.renderer`: it draws nothing, and keeps what it
 * was asked of the viewer's canvas (the first it is given; another, a view cube's, it draws on
 * unrecorded): how many frames, the scene and the camera of the last, and whether it was
 * disposed; and of every canvas, how many renderers were made and how many let their context
 * go. As a WebGLRenderer does, it brings the scene's and the camera's matrices up to date: the
 * camera's controls pan along them.
 */
export function stubRenderer() {
  const drawn = {
    renders: 0,
    /** @type {Object3D | null} */
    scene: null,
    /** @type {Camera | null} */
    camera: null,
    disposed: false,
    made: 0,
    released: 0,
  };
  /** @type {HTMLCanvasElement | null} */
  let viewers = null;
  /**
   * @param {HTMLCanvasElement} canvas
   * @returns {RendererLike}
   */
  const renderer = (canvas) => {
    viewers ??= canvas;
    const recorded = canvas === viewers;
    drawn.made += 1;
    return {
      localClippingEnabled: false,
      setPixelRatio() {},
      setSize() {},
      render(scene, camera) {
        scene.updateMatrixWorld();
        if (camera.parent === null) camera.updateMatrixWorld();
        if (!recorded) return;
        drawn.renders += 1;
        drawn.scene = scene;
        drawn.camera = camera;
      },
      dispose() {
        if (recorded) drawn.disposed = true;
      },
      forceContextLoss() {
        drawn.released += 1;
      },
    };
  };
  return { renderer, drawn };
}
