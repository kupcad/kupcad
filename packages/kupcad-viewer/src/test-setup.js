// What jsdom lacks of a browser and the viewer uses: the component watches its canvas's size,
// and the camera's controls capture the pointer while it drags.

globalThis.ResizeObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
};

Element.prototype.setPointerCapture ??= () => {};
Element.prototype.releasePointerCapture ??= () => {};
Element.prototype.hasPointerCapture ??= () => false;
