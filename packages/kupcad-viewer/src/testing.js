// What jsdom lacks of a browser and the viewer uses, for a host's tests that mount it (a
// Vitest `setupFiles` entry): the component watches its canvas's size, the camera's controls
// capture the pointer while it drags, and a screenshot reads the canvas as an image, which
// jsdom draws none of: here an empty PNG.

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
