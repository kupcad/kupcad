import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { stubRenderer } from './viewer/testing.js';
import { createRawSnippet, tick } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { bound } from './bound.test-helper.svelte.js';
import { modelOf, PARTS } from './fixtures.test-helper.js';
import { memorySettings } from './settings.js';
import ViewerPane from './ViewerPane.svelte';

/** @import { Viewer } from './viewer/index.js' */
/** @import { Problem } from './run-status.js' */
/** @import { Settings } from './settings.js' */
/** @import { ShortcutGroup } from './shortcuts.js' */

/**
 * The pane showing `source`'s model (the parts', by default), once the viewer shows it: the
 * viewer, what it drew, and what the pane's bindings and its screenshot callback were given.
 * @param {string} [source]
 * @param {{ settings?: Settings, shortcuts?: ShortcutGroup[] }} [props] what else the pane is
 *   given
 */
async function pane(source = PARTS, props = {}) {
  const { renderer, drawn } = stubRenderer();
  const viewer = bound(/** @type {Viewer | null} */ (null));
  const selected = bound(/** @type {string | null} */ (null));
  /** @type {Blob[]} */
  const images = [];
  const { rerender } = render(ViewerPane, {
    props: {
      model: await modelOf(source),
      options: { renderer },
      ...props,
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

/**
 * Whether the button named `name` is pressed, as its aria-pressed says.
 * @param {string} name
 */
const pressed = (name) => screen.getByRole('button', { name }).getAttribute('aria-pressed');

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

  it("sets the viewer's render mode, edges, axes, floor, perspective and view from its controls", async () => {
    const { viewer } = await pane();
    expect(screen.getByRole('toolbar', { name: 'View' })).toBeTruthy();
    // Drawn as .kc-control, the look a host's own actions take
    expect(screen.getByRole('button', { name: 'Fit' }).classList.contains('kc-control')).toBe(true);
    await fireEvent.click(screen.getByRole('button', { name: 'X-ray' }));
    expect(viewer.renderMode).toBe('xray');
    await fireEvent.click(screen.getByRole('button', { name: 'Wireframe' }));
    expect(viewer.renderMode).toBe('wireframe');
    expect([pressed('Wireframe'), pressed('X-ray')]).toEqual(['true', 'false']);
    await fireEvent.click(screen.getByRole('button', { name: 'Edges' }));
    expect(viewer.edges).toBe(false);
    expect(viewer.axes).toBe(true);
    await fireEvent.click(screen.getByRole('button', { name: 'Axes' }));
    expect(viewer.axes).toBe(false);
    expect(pressed('Axes')).toBe('false');
    await fireEvent.click(screen.getByRole('button', { name: 'Perspective' }));
    expect(viewer.projection).toBe('orthographic');
    await fireEvent.click(screen.getByRole('button', { name: 'Plate' }));
    expect(viewer.environment).toBe('plate');
    // Pressed again, there is no floor
    await fireEvent.click(screen.getByRole('button', { name: 'Plate' }));
    expect(viewer.environment).toBe('none');
    await fireEvent.click(screen.getByRole('button', { name: 'Front' }));
    expect(viewer.view).toBe('front');
    expect(pressed('Front')).toBe('true');
    // A key the viewer takes (Orca Slicer's Ctrl+1, the top) shows in the controls
    const canvas = /** @type {HTMLCanvasElement} */ (document.querySelector('canvas'));
    await fireEvent.keyDown(canvas, { key: '1', ctrlKey: true });
    expect([pressed('Top'), pressed('Front')]).toEqual(['true', 'false']);
  });

  it('keeps the view chosen in its settings, and starts as they keep it', async () => {
    const settings = memorySettings({
      'view.renderMode': 'wireframe',
      'view.edges': false,
      'view.environment': 'plate',
      'view.projection': 'orthographic',
    });
    const { viewer } = await pane(PARTS, { settings });
    expect([viewer.renderMode, viewer.edges, viewer.axes]).toEqual(['wireframe', false, true]);
    expect([viewer.environment, viewer.projection]).toEqual(['plate', 'orthographic']);
    expect([pressed('Wireframe'), pressed('Edges'), pressed('Plate')]).toEqual([
      'true',
      'false',
      'true',
    ]);
    expect(pressed('Perspective')).toBe('false');

    await fireEvent.click(screen.getByRole('button', { name: 'X-ray' }));
    await fireEvent.click(screen.getByRole('button', { name: 'Axes' }));
    await fireEvent.click(screen.getByRole('button', { name: 'Grid' }));
    await fireEvent.click(screen.getByRole('button', { name: 'Perspective' }));
    expect(viewer.projection).toBe('perspective');
    expect(
      ['renderMode', 'edges', 'axes', 'environment', 'projection'].map((key) =>
        settings.get(`view.${key}`),
      ),
    ).toEqual(['xray', false, false, 'grid', 'perspective']);
  });

  it('follows its view as its settings are set elsewhere: a settings page, another pane', async () => {
    const settings = memorySettings();
    const { viewer } = await pane(PARTS, { settings });
    settings.set('view.renderMode', 'xray');
    settings.set('view.edges', false);
    settings.set('view.environment', 'none');
    settings.set('view.projection', 'orthographic');
    await tick();
    expect([pressed('X-ray'), pressed('Solid'), pressed('Edges')]).toEqual([
      'true',
      'false',
      'false',
    ]);
    expect([pressed('Grid'), pressed('Plate'), pressed('Perspective')]).toEqual([
      'false',
      'false',
      'false',
    ]);
    expect([viewer.renderMode, viewer.edges, viewer.environment, viewer.projection]).toEqual([
      'xray',
      false,
      'none',
      'orthographic',
    ]);
  });

  it("takes a drawing's top orthographic view for no choice: a solid after it is seen as chosen", async () => {
    const settings = memorySettings();
    const { viewer, show } = await pane(PARTS, { settings });
    await show('square(10)');
    expect([viewer.projection, pressed('Perspective')]).toEqual(['orthographic', 'false']);
    // Another choice while it shows changes the drawing's projection not
    await fireEvent.click(screen.getByRole('button', { name: 'Edges' }));
    expect(viewer.projection).toBe('orthographic');
    expect(settings.get('view.projection')).toBeUndefined();
    await show(PARTS);
    expect([viewer.projection, pressed('Perspective')]).toEqual(['perspective', 'true']);

    // Chosen while a drawing shows, the choice is the next solid's, not how the last was seen
    await fireEvent.click(screen.getByRole('button', { name: 'Perspective' }));
    expect(viewer.projection).toBe('orthographic');
    await show('square(12)');
    await fireEvent.click(screen.getByRole('button', { name: 'Perspective' }));
    expect(settings.get('view.projection')).toBe('perspective');
    await show(PARTS);
    expect([viewer.projection, pressed('Perspective')]).toEqual(['perspective', 'true']);
  });

  it("lists the keyboard shortcuts from its bottom bar, the host's before the viewer's", async () => {
    await pane(PARTS, { shortcuts: [{ title: 'App', keys: [['⌘S', 'Save the script']] }] });
    const button = screen.getByRole('button', { name: 'Keyboard shortcuts' });
    // At the end of the bar with the run's status, there before any run
    expect(button.closest('.run')).toBeTruthy();
    expect(button.getAttribute('aria-haspopup')).toBe('dialog');
    expect(screen.queryByRole('dialog')).toBeNull();
    button.focus();
    await fireEvent.click(button);
    const dialog = screen.getByRole('dialog', { name: 'Keyboard shortcuts' });
    const titles = within(dialog)
      .getAllByRole('heading', { level: 3 })
      .map((heading) => heading.textContent);
    expect(titles).toEqual(['App', 'Viewer']);
    expect(within(dialog).getByText('Move the section')).toBeTruthy();
    await fireEvent.keyDown(dialog, { key: 'Escape' });
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(document.activeElement).toBe(button);
  });

  it('shows what the pointer is over by it: the part, its copies and measures, the face', async () => {
    const { viewer } = await pane();
    /** @param {import('./viewer/types.js').HoverDetail} detail */
    const hover = async (detail) => {
      viewer.dispatchEvent(new CustomEvent('hover', { detail }));
      await tick();
    };
    const face = {
      flat: true,
      area: 12.57,
      normal: /** @type {[number, number, number]} */ ([0, 0, 1]),
      facing: '+Z (top)',
    };
    await hover({ part: 'bolt', face, x: 40, y: 30 });
    const tip = screen.getByRole('tooltip');
    expect(tip.textContent).toContain('bolt ×2');
    // Measured by the core as made: up to 4 mm across, 5 high
    expect(tip.textContent).toMatch(/[\d.]+ mm³ · [\d.]+ × [\d.]+ × 5 mm/);
    expect(tip.textContent).toContain('Flat face · 12.6 mm² · facing +Z (top)');
    expect([tip.style.left, tip.style.top]).toEqual(['54px', '44px']);
    // A nameless part's face alone, and nothing once the pointer is over nothing
    await hover({ part: null, face: { ...face, flat: false }, x: 0, y: 0 });
    expect(screen.getByRole('tooltip').textContent?.trim()).toBe('Curved face · 12.6 mm²');
    await hover(null);
    expect(screen.queryByRole('tooltip')).toBeNull();
  });

  it('says how the run went: its state, its time and its warnings', async () => {
    const { rerender } = render(ViewerPane, {
      props: {
        model: await modelOf(PARTS),
        options: { renderer: stubRenderer().renderer },
        status: { state: 'running' },
      },
    });
    expect(screen.getByRole('status').textContent?.trim()).toBe('Running…');
    await rerender({ status: { state: 'ready', runMs: 183.6, warnings: 2 } });
    expect(screen.getByRole('status').textContent?.trim()).toBe('Ready · 184 ms · 2 warnings');
    await rerender({ status: { state: 'failed', runMs: 12, warnings: 1 } });
    expect(screen.getByRole('status').textContent?.trim()).toBe('Failed · 12 ms · 1 warning');
    await rerender({ status: null });
    expect(screen.queryByRole('status')).toBeNull();
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

  it('follows the section the wheel moves in the viewer, with Option', async () => {
    const { viewer } = await pane();
    const canvas = /** @type {HTMLCanvasElement} */ (document.querySelector('canvas'));
    // The parts reach from z 0 to 7: 2000 pixels cross them, from the top down
    await fireEvent.wheel(canvas, { deltaY: 1000, altKey: true });
    expect(
      /** @type {HTMLInputElement} */ (screen.getByRole('checkbox', { name: 'Section' })).checked,
    ).toBe(true);
    const slider = /** @type {HTMLInputElement} */ (
      screen.getByRole('slider', { name: 'Section offset' })
    );
    expect(Number(slider.value)).toBeCloseTo(3.5, 1);
    expect(viewer.section?.offset).toBeCloseTo(3.5, 6);
  });

  it('says how the viewer looks at a drawing: from the top, orthographic', async () => {
    const { viewer } = await pane('square(10)');
    expect(viewer.projection).toBe('orthographic');
    expect([pressed('Perspective'), pressed('Top')]).toEqual(['false', 'true']);
  });

  it('offers no section through a drawing, which the viewer cuts not, and lists no parts', async () => {
    const { show } = await pane();
    const sectioned = /** @type {HTMLInputElement} */ (
      screen.getByRole('checkbox', { name: 'Section' })
    );
    expect(sectioned.disabled).toBe(false);
    await show('square(10)');
    expect(sectioned.disabled).toBe(true);
    expect(screen.queryByRole('list', { name: 'Parts' })).toBeNull();
    expect(document.querySelector('.parts')?.textContent?.replace(/\s+/g, ' ').trim()).toBe(
      'Parts None',
    );
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

  it("ends its toolbar with the host's own buttons, then the panel's", async () => {
    const viewer = bound(/** @type {Viewer | null} */ (null));
    render(ViewerPane, {
      props: {
        model: await modelOf(PARTS),
        options: { renderer: stubRenderer().renderer },
        actions: createRawSnippet(() => ({
          render: () => '<button type="button">Export…</button>',
        })),
        get viewer() {
          return viewer.value;
        },
        set viewer(made) {
          viewer.value = made;
        },
      },
    });
    const toolbar = /** @type {HTMLElement} */ (document.querySelector('.toolbar'));
    const buttons = [...toolbar.querySelectorAll('button')].map((b) => b.textContent?.trim());
    expect(buttons.slice(-2)).toEqual(['Export…', 'Panel']);
  });

  it('hides the panel of controls and parts, and shows it again', async () => {
    await pane();
    const toggle = screen.getByRole('button', { name: 'Panel' });
    const panel = /** @type {HTMLElement} */ (
      document.getElementById(/** @type {string} */ (toggle.getAttribute('aria-controls')))
    );
    expect(panel.getAttribute('aria-label')).toBe('View and parts');
    expect([toggle.getAttribute('aria-expanded'), panel.hidden]).toEqual(['true', false]);
    // The controls over the parts, in the one panel
    expect(panel.contains(screen.getByRole('toolbar', { name: 'View' }))).toBe(true);
    expect(panel.contains(screen.getByRole('list', { name: 'Parts' }))).toBe(true);
    await fireEvent.click(toggle);
    expect([toggle.getAttribute('aria-expanded'), panel.hidden]).toEqual(['false', true]);
    await fireEvent.click(toggle);
    expect(panel.hidden).toBe(false);
  });

  it('lists what the run said went wrong, one with a line clicked given to the host', async () => {
    /** @type {Problem[]} */
    const clicked = [];
    /** @type {Problem[]} */
    const problems = [
      { severity: 'error', message: 'undefined variable `w`', line: 3, column: 7 },
      { severity: 'warning', message: 'meshed coarse', line: null, column: null },
    ];
    const { rerender } = render(ViewerPane, {
      props: {
        model: await modelOf(PARTS),
        options: { renderer: stubRenderer().renderer },
        problems,
        onproblem: (/** @type {Problem} */ problem) => clicked.push(problem),
      },
    });
    const list = screen.getByRole('list', { name: 'Problems' });
    const said = [...list.querySelectorAll('li')].map((li) =>
      li.textContent?.replace(/\s+/g, ' ').trim(),
    );
    expect(said).toEqual(['Error undefined variable `w` line 3', 'Warning meshed coarse']);
    // The warning has no line: nothing to show in the script
    const buttons = list.querySelectorAll('button');
    expect(buttons).toHaveLength(1);
    await fireEvent.click(buttons[0]);
    expect(clicked).toEqual([problems[0]]);
    // Without a host to show them, none is clicked; with none, there is no list
    await rerender({ onproblem: undefined });
    expect(screen.getByRole('list', { name: 'Problems' }).querySelector('button')).toBeNull();
    await rerender({ problems: [] });
    expect(screen.queryByRole('list', { name: 'Problems' })).toBeNull();
  });

  it('gives a screenshot to its host', async () => {
    const { images } = await pane();
    await fireEvent.click(screen.getByRole('button', { name: 'Screenshot' }));
    await vi.waitFor(() => expect(images).toHaveLength(1));
  });
});
