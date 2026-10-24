// For a host's tests of the viewer. Imported (a Vitest `setupFiles` entry, say), it gives jsdom
// what a browser has and the viewer uses: the component watches its canvas's size, the camera's
// controls capture the pointer while it drags, and a screenshot reads the canvas as an image,
// which jsdom draws none of: here an empty PNG. `stubRenderer` draws in place of WebGL, which
// jsdom lacks.

/** @import { Camera, Object3D } from 'three' */
/** @import { RendererLike } from './types.js' */

globalThis.ResizeObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
};

Element.prototype.setPointerCapture ??= () => {};
Element.prototype.releasePointerCapture ??= () => {};
Element.prototype.hasPointerCapture ??= () => false;

/** @type {HTMLCanvasElement['toBlob']} */
HTMLCanvasElement.prototype.toBlob = function toBlob(callback, type = 'image/png') {
  callback(new Blob([], { type }));
};

/**
 * A stand-in for WebGL, for a Viewer's `options.renderer`: it draws nothing, and keeps what it
 * was asked: how many frames, the scene and the camera of the last, and whether it was disposed.
 */
export function stubRenderer() {
  const drawn = {
    renders: 0,
    /** @type {Object3D | null} */
    scene: null,
    /** @type {Camera | null} */
    camera: null,
    disposed: false,
  };
  /** @returns {RendererLike} */
  const renderer = () => ({
    localClippingEnabled: false,
    setPixelRatio() {},
    setSize() {},
    render(scene, camera) {
      drawn.renders += 1;
      drawn.scene = scene;
      drawn.camera = camera;
    },
    dispose() {
      drawn.disposed = true;
    },
  });
  return { renderer, drawn };
}
