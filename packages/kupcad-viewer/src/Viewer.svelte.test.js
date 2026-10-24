import { render } from '@testing-library/svelte';
import { expect, it, vi } from 'vitest';
import { modelOf } from './models.test-helper.js';
import ViewerComponent from './Viewer.svelte';

/** @import { RendererLike } from './types.js' */
/** @import { Viewer } from './viewer.js' */

it('makes a Viewer on its canvas, in the state its props give, binds the part clicked, and frees it unmounted', async () => {
  let disposed = false;
  /** @returns {RendererLike} */
  const renderer = () => ({
    localClippingEnabled: false,
    setPixelRatio() {},
    setSize() {},
    render() {},
    dispose() {
      disposed = true;
    },
  });
  /** @type {Viewer | null} */
  let viewer = null;
  /** @type {string | null} */
  let selected = null;
  let models = 0;
  const model = await modelOf('cube(20, center: true).named("block")');
  const { container, rerender, unmount } = render(ViewerComponent, {
    props: {
      model,
      renderMode: 'xray',
      options: { renderer },
      onmodel: () => {
        models += 1;
      },
      get viewer() {
        return viewer;
      },
      set viewer(made) {
        viewer = made;
      },
      get selected() {
        return selected;
      },
      set selected(part) {
        selected = part;
      },
    },
  });
  await vi.waitFor(() => expect(models).toBe(1));
  const shown = /** @type {Viewer} */ (/** @type {unknown} */ (viewer));
  expect(shown.partAt(0.5, 0.5)).toBe('block');
  expect(shown.renderMode).toBe('xray');
  await rerender({ renderMode: 'wireframe', section: { axis: 'z', offset: 0 } });
  expect(shown.renderMode).toBe('wireframe');
  expect(shown.section).toEqual({ axis: 'z', offset: 0 });

  const canvas = /** @type {HTMLCanvasElement} */ (container.querySelector('canvas'));
  for (const type of ['pointerdown', 'pointerup']) {
    canvas.dispatchEvent(Object.assign(new Event(type), { offsetX: 0.5, offsetY: 0.5 }));
  }
  expect(selected).toBe('block');

  unmount();
  expect(disposed).toBe(true);
  expect(viewer).toBeNull();
});
