import { fireEvent, render, screen } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';
import SettingsPane from './SettingsPane.svelte';

/** @import { Theme } from './theme.js' */

/** The pane with the theme and the console as given, and what it was told. */
function paneOf(/** @type {Theme} */ theme = 'system', shows = true) {
  const props = {
    theme,
    console: shows,
    ontheme: vi.fn(),
    onconsole: vi.fn(),
    onclose: vi.fn(),
  };
  render(SettingsPane, { props });
  return props;
}

const radio = (/** @type {string} */ name) =>
  /** @type {HTMLInputElement} */ (screen.getByRole('radio', { name }));
const consoleBox = () =>
  /** @type {HTMLInputElement} */ (
    screen.getByRole('checkbox', { name: 'Show the console under the model' })
  );

describe('the settings pane', () => {
  it('shows the theme and the console as they are', () => {
    paneOf('dark', false);
    const themes = screen.getByRole('radiogroup', { name: 'Theme' });
    expect(themes.getAttribute('aria-describedby')).toBeTruthy();
    expect(
      document.getElementById(/** @type {string} */ (themes.getAttribute('aria-describedby')))
        ?.textContent,
    ).toBe("System follows your computer's appearance.");
    expect(['System', 'Light', 'Dark'].map((name) => radio(name).checked)).toEqual([
      false,
      false,
      true,
    ]);
    expect(consoleBox().checked).toBe(false);
  });

  it('tells the theme chosen', async () => {
    const props = paneOf();
    expect(radio('System').checked).toBe(true);
    await fireEvent.click(radio('Light'));
    expect(props.ontheme).toHaveBeenCalledExactlyOnceWith('light');
  });

  it('tells whether the console shows', async () => {
    const props = paneOf();
    expect(consoleBox().checked).toBe(true);
    await fireEvent.click(consoleBox());
    expect(props.onconsole).toHaveBeenCalledExactlyOnceWith(false);
  });

  it('tells when it is closed', async () => {
    const props = paneOf();
    await fireEvent.click(screen.getByRole('button', { name: 'Close settings' }));
    expect(props.onclose).toHaveBeenCalledOnce();
  });
});
