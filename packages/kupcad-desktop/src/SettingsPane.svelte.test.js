import { memorySettings } from '@kupcad/ui';
import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { tick } from 'svelte';
import { describe, expect, it, vi } from 'vitest';
import SettingsPane from './SettingsPane.svelte';

/** The pane on `settings`, and what it was told. */
function paneOf(settings = memorySettings()) {
  const onclose = vi.fn();
  render(SettingsPane, { props: { settings, onclose } });
  return { settings, onclose };
}

/** The radio named `name` of the choice titled `group`. */
const radio = (/** @type {string} */ group, /** @type {string} */ name) =>
  /** @type {HTMLInputElement} */ (
    within(screen.getByRole('radiogroup', { name: group })).getByRole('radio', { name })
  );
const chosen = (/** @type {string} */ group) =>
  within(screen.getByRole('radiogroup', { name: group }))
    .getAllByRole('radio')
    .filter((input) => /** @type {HTMLInputElement} */ (input).checked)
    .map((input) => input.closest('label')?.textContent?.trim());
const box = (/** @type {string} */ name) =>
  /** @type {HTMLInputElement} */ (screen.getByRole('checkbox', { name }));
const fontSize = () =>
  /** @type {HTMLSelectElement} */ (screen.getByRole('combobox', { name: 'Editor font size' }));

/** The checkboxes' names, in the pane's order. */
const BOXES = [
  'Open the last folder when KupCAD starts',
  'Save a script a moment after each change',
  "Draw the shapes' edges",
  'Draw the axes through the origin',
  'Show the console under the model',
];

describe('the settings pane', () => {
  it("shows the app's defaults where nothing is kept", () => {
    paneOf();
    expect(chosen('Theme')).toEqual(['System']);
    expect(fontSize().value).toBe('13');
    expect(BOXES.map((name) => box(name).checked)).toEqual([true, false, true, true, true]);
    expect([chosen('Render mode'), chosen('Projection'), chosen('Floor')]).toEqual([
      ['Solid'],
      ['Perspective'],
      ['Grid'],
    ]);
  });

  it('shows the settings as they are kept', () => {
    paneOf(
      memorySettings({
        'app.theme': 'dark',
        'app.fontSize': 16,
        'app.reopen': false,
        'app.autosave': true,
        'app.console': false,
        'view.renderMode': 'xray',
        'view.projection': 'orthographic',
        'view.environment': 'plate',
        'view.edges': false,
        'view.axes': false,
      }),
    );
    expect(chosen('Theme')).toEqual(['Dark']);
    expect(fontSize().value).toBe('16');
    expect(BOXES.map((name) => box(name).checked)).toEqual([false, true, false, false, false]);
    expect([chosen('Render mode'), chosen('Projection'), chosen('Floor')]).toEqual([
      ['X-ray'],
      ['Orthographic'],
      ['Plate'],
    ]);
  });

  it('keeps each choice in the settings as it is made', async () => {
    const { settings } = paneOf();
    await fireEvent.click(radio('Theme', 'Light'));
    await fireEvent.change(fontSize(), { target: { value: '18' } });
    for (const name of BOXES) await fireEvent.click(box(name));
    await fireEvent.click(radio('Render mode', 'Wireframe'));
    await fireEvent.click(radio('Projection', 'Orthographic'));
    await fireEvent.click(radio('Floor', 'None'));
    expect(
      [
        'app.theme',
        'app.fontSize',
        'app.reopen',
        'app.autosave',
        'view.edges',
        'view.axes',
        'app.console',
        'view.renderMode',
        'view.projection',
        'view.environment',
      ].map((key) => settings.get(key)),
    ).toEqual(['light', 18, false, true, false, false, false, 'wireframe', 'orthographic', 'none']);
  });

  it("follows the settings set elsewhere: the preview's toolbar, say", async () => {
    const { settings } = paneOf();
    settings.set('view.renderMode', 'xray');
    settings.set('app.autosave', true);
    await tick();
    expect(chosen('Render mode')).toEqual(['X-ray']);
    expect(box('Save a script a moment after each change').checked).toBe(true);
  });

  it('tells when it is closed', async () => {
    const { onclose } = paneOf();
    await fireEvent.click(screen.getByRole('button', { name: 'Close settings' }));
    expect(onclose).toHaveBeenCalledOnce();
  });
});
