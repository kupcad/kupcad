import { render } from '@testing-library/svelte';
import { expect, it, vi } from 'vitest';
import { dracoModelOf, modelOf } from './models.test-helper.js';
import { stubRenderer } from './testing.js';
import ViewerComponent from './Viewer.svelte';
import { ViewerError } from './viewer.js';

/** @import { Viewer } from './viewer.js' */

it('makes a Viewer on its canvas, in the state its props give, binds the part clicked, and frees it unmounted', async () => {
  const { renderer, drawn } = stubRenderer();
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
  // A selection the host makes reaches the viewer
  await rerender({ selected: 'block' });
  expect(shown.selected).toBe('block');
  await rerender({ selected: null });

  const canvas = /** @type {HTMLCanvasElement} */ (container.querySelector('canvas'));
  expect(canvas.getAttribute('aria-label')).toBe('The model');
  for (const type of ['pointerdown', 'pointerup']) {
    canvas.dispatchEvent(Object.assign(new Event(type), { offsetX: 0.5, offsetY: 0.5 }));
  }
  expect(selected).toBe('block');

  unmount();
  expect(drawn.disposed).toBe(true);
  expect(viewer).toBeNull();
});

it("passes a model it can't show to onerror, and not an error of onmodel's own", async () => {
  const { renderer } = stubRenderer();
  /** @type {unknown[]} */
  const errors = [];
  let shown = 0;
  const { rerender } = render(ViewerComponent, {
    props: {
      model: await dracoModelOf('cube(1)'),
      options: { renderer },
      onmodel: () => {
        shown += 1;
        if (shown === 1) throw new Error("the host's own");
      },
      onerror: (error) => errors.push(error),
    },
  });
  await vi.waitFor(() => expect(errors).toHaveLength(1));
  expect(errors[0]).toBeInstanceOf(ViewerError);

  // The host's handler failing is the host's: it doesn't reach onerror
  const unhandled = vi.fn();
  process.on('unhandledRejection', unhandled);
  try {
    await rerender({ model: await modelOf('cube(1)') });
    await vi.waitFor(() => expect(unhandled).toHaveBeenCalledOnce());
  } finally {
    process.off('unhandledRejection', unhandled);
  }
  expect(errors).toHaveLength(1);
});
