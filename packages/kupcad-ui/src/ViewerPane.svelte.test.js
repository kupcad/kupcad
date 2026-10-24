import { fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { describe, expect, it, vi } from 'vitest';
import { bound } from './bound.test-helper.svelte.js';
import { modelOf, PARTS } from './fixtures.test-helper.js';
import ViewerPane from './ViewerPane.svelte';

/** @import { RendererLike } from '@kupcad/viewer/types' */
/** @import { Viewer } from '@kupcad/viewer' */

/** @returns {RendererLike} */
const renderer = () => ({
  localClippingEnabled: false,
  setPixelRatio() {},
  setSize() {},
  render() {},
  dispose() {},
});

/**
 * The pane showing the parts model, once the viewer shows it: the viewer, and what the pane's
 * bindings and its screenshot callback were given.
 */
async function pane() {
  const viewer = bound(/** @type {Viewer | null} */ (null));
  const selected = bound(/** @type {string | null} */ (null));
  /** @type {Blob[]} */
  const images = [];
  render(ViewerPane, {
    props: {
      model: await modelOf(PARTS),
      options: { renderer },
      onscreenshot: (/** @type {Blob} */ image) => images.push(image),
      get viewer() {
        return viewer.value;
      },
      set viewer(made) {
        viewer.value = made;
      },
      get selected() {
        return selected.value;
      },
      set selected(part) {
        selected.value = part;
      },
    },
  });
  await vi.waitFor(() => expect(viewer.value?.bounds).not.toBeNull());
  return { selected, images, viewer: /** @type {Viewer} */ (viewer.value) };
}

describe('ViewerPane', () => {
  it("lists the model's parts, a click selecting every copy, another taking it back", async () => {
    const { selected, viewer } = await pane();
    const parts = screen.getByRole('list', { name: 'Parts' });
    expect(parts.textContent?.replace(/\s+/g, ' ').trim()).toBe('plate bolt ×2');
    const bolt = screen.getByRole('button', { name: /bolt/ });
    await fireEvent.click(bolt);
    expect(selected.value).toBe('bolt');
    expect(viewer.selected).toBe('bolt');
    expect(bolt.getAttribute('aria-pressed')).toBe('true');
    await fireEvent.click(bolt);
    expect(viewer.selected).toBeNull();
  });

  it("sets the viewer's render mode, projection, floor and view from its toolbar", async () => {
    const { viewer } = await pane();
    await fireEvent.click(screen.getByRole('button', { name: 'X-ray' }));
    expect(viewer.renderMode).toBe('xray');
    await fireEvent.click(screen.getByRole('checkbox', { name: 'Orthographic' }));
    expect(viewer.projection).toBe('orthographic');
    await fireEvent.change(screen.getByRole('combobox', { name: 'Floor' }), {
      target: { value: 'plate' },
    });
    expect(viewer.environment).toBe('plate');
    await fireEvent.change(screen.getByRole('combobox', { name: 'View' }), {
      target: { value: 'front' },
    });
    expect(viewer.view).toBe('front');
  });

  it('cuts a section across the middle of the model, along the axis chosen', async () => {
    const { viewer } = await pane();
    await fireEvent.click(screen.getByRole('checkbox', { name: 'Section' }));
    await tick();
    // The parts reach from z 0 to 7: the cut starts halfway
    expect(viewer.section?.axis).toBe('z');
    expect(viewer.section?.offset).toBeCloseTo(3.5, 6);
    await fireEvent.change(screen.getByRole('combobox', { name: 'Section axis' }), {
      target: { value: 'x' },
    });
    await tick();
    expect(viewer.section?.axis).toBe('x');
    expect(viewer.section?.offset).toBeCloseTo(10, 6);
    const slider = /** @type {HTMLInputElement} */ (
      screen.getByRole('slider', { name: 'Section offset' })
    );
    expect(Number(slider.min)).toBeCloseTo(0, 6);
    expect(Number(slider.max)).toBeCloseTo(20, 6);
  });

  it('gives a screenshot to its host', async () => {
    const { images } = await pane();
    await fireEvent.click(screen.getByRole('button', { name: 'Screenshot' }));
    await vi.waitFor(() => expect(images).toHaveLength(1));
  });
});
