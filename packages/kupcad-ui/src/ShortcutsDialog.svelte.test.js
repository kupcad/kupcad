import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { tick } from 'svelte';
import { describe, expect, it } from 'vitest';
import { bound } from './bound.test-helper.svelte.js';
import ShortcutsDialog from './ShortcutsDialog.svelte';

/** @import { ShortcutGroup } from './shortcuts.js' */

/** @type {ShortcutGroup[]} */
const GROUPS = [
  { title: 'App', keys: [['⌘S', 'Save the script']] },
  { title: 'Viewer', note: 'Click the model first.', keys: [['F', 'Fit the model']] },
];

/** The dialog of GROUPS, closed, its `open` bound; and a button that had the focus. */
function dialogOf() {
  const opener = document.createElement('button');
  document.body.append(opener);
  opener.focus();
  const open = bound(false);
  render(ShortcutsDialog, {
    props: {
      groups: GROUPS,
      get open() {
        return open.value;
      },
      set open(next) {
        open.value = next;
      },
    },
  });
  const dialog = /** @type {HTMLDialogElement} */ (document.querySelector('dialog'));
  return { open, dialog, opener };
}

describe('ShortcutsDialog', () => {
  it('shows each group under its title, the keys and what they do, while open', async () => {
    const { open, dialog } = dialogOf();
    expect(dialog.open).toBe(false);
    open.value = true;
    await tick();
    expect(dialog.open).toBe(true);
    const shown = screen.getByRole('dialog', { name: 'Keyboard shortcuts' });
    const titles = within(shown)
      .getAllByRole('heading', { level: 3 })
      .map((heading) => heading.textContent);
    expect(titles).toEqual(['App', 'Viewer']);
    const viewer = within(shown).getByRole('region', { name: 'Viewer' });
    expect(viewer.textContent).toContain('Click the model first.');
    expect(within(viewer).getByText('F').tagName).toBe('KBD');
    expect(within(viewer).getByText('Fit the model')).toBeTruthy();
  });

  it('closes by its button or Escape, the focus back where it was', async () => {
    const { open, dialog, opener } = dialogOf();
    open.value = true;
    await tick();
    within(dialog).getByRole('button', { name: 'Close' }).focus();
    await fireEvent.click(within(dialog).getByRole('button', { name: 'Close' }));
    expect([dialog.open, open.value]).toEqual([false, false]);
    expect(document.activeElement).toBe(opener);

    open.value = true;
    await tick();
    await fireEvent.keyDown(dialog, { key: 'Escape' });
    expect([dialog.open, open.value]).toEqual([false, false]);
    expect(document.activeElement).toBe(opener);
  });

  it('closes when its host says so', async () => {
    const { open, dialog } = dialogOf();
    open.value = true;
    await tick();
    open.value = false;
    await tick();
    expect(dialog.open).toBe(false);
  });
});
