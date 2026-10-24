import { fireEvent, render, screen } from '@testing-library/svelte';
import { stubRenderer } from '@kupcad/viewer/testing';
import { tick } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { bound } from './bound.test-helper.svelte.js';
import { modelOf, PARTS } from './fixtures.test-helper.js';
import ViewerPane from './ViewerPane.svelte';

/** @import { Viewer } from '@kupcad/viewer' */

/**
 * The pane showing `source`'s model (the parts', by default), once the viewer shows it: the
 * viewer, what it drew, and what the pane's bindings and its screenshot callback were given.
 */
async function pane(source = PARTS) {
  const { renderer, drawn } = stubRenderer();
  const viewer = bound(/** @type {Viewer | null} */ (null));
  const selected = bound(/** @type {string | null} */ (null));
  /** @type {Blob[]} */
  const images = [];
  const { rerender } = render(ViewerPane, {
    props: {
      model: await modelOf(source),
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
  /**
   * Shows `next`'s model in place, once the viewer shows it (its bounds differ).
   * @param {string} next
   */
  const show = async (next) => {
    const shown = /** @type {Viewer} */ (viewer.value);
    const before = shown.bounds;
    await rerender({ model: await modelOf(next) });
    await vi.waitFor(() => expect(shown.bounds).not.toEqual(before));
  };
  return { selected, images, drawn, show, viewer: /** @type {Viewer} */ (viewer.value) };
}

/**
 * The background the viewer drew last, as hex, once it draws again.
 * @param {{ scene: unknown }} drawn
 */
async function backgroundDrawn(drawn) {
  await new Promise((resolve) => requestAnimationFrame(resolve));
  const scene = /** @type {{ background: { getHexString(): string } }} */ (drawn.scene);
  return `#${scene.background.getHexString()}`;
}

afterEach(() => document.documentElement.removeAttribute('style'));

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

  it('says how the viewer looks at a drawing: from the top, orthographic', async () => {
    const { viewer } = await pane('square(10)');
    expect(viewer.projection).toBe('orthographic');
    expect(
      /** @type {HTMLInputElement} */ (screen.getByRole('checkbox', { name: 'Orthographic' }))
        .checked,
    ).toBe(true);
    expect(
      /** @type {HTMLSelectElement} */ (screen.getByRole('combobox', { name: 'View' })).value,
    ).toBe('top');
  });

  it('keeps a section where it was through an edit, and puts it across a model it misses', async () => {
    const { viewer, show } = await pane();
    await fireEvent.click(screen.getByRole('checkbox', { name: 'Section' }));
    await fireEvent.input(screen.getByRole('slider', { name: 'Section offset' }), {
      target: { value: '1' },
    });
    await tick();
    expect(viewer.section?.offset).toBe(1);
    await show(PARTS.replace('cube([20, 10, 2])', 'cube([30, 10, 2])'));
    expect(viewer.section?.offset).toBe(1);
    // Raised past it, the model is cut across its middle again
    await show('cube(10).translate(z: 50)');
    expect(viewer.section?.offset).toBeCloseTo(55, 6);
  });

  it("follows the page's --kc-viewer-* tokens as they change, an alpha left out", async () => {
    const { drawn } = await pane();
    document.documentElement.style.setProperty('--kc-viewer-background', '#102030');
    await vi.waitFor(async () => expect(await backgroundDrawn(drawn)).toBe('#102030'));
    document.documentElement.style.setProperty('--kc-viewer-background', '#405060ff');
    await vi.waitFor(async () => expect(await backgroundDrawn(drawn)).toBe('#405060'));
  });

  it('frames the model again on Fit, from the view it looks from', async () => {
    const { viewer } = await pane();
    const fit = vi.spyOn(viewer, 'fit');
    await fireEvent.click(screen.getByRole('button', { name: 'Fit' }));
    expect(fit).toHaveBeenCalledOnce();
  });

  it('gives a screenshot to its host', async () => {
    const { images } = await pane();
    await fireEvent.click(screen.getByRole('button', { name: 'Screenshot' }));
    await vi.waitFor(() => expect(images).toHaveLength(1));
  });
});
