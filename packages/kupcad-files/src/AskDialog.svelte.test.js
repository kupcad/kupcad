import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import AskDialog from './AskDialog.svelte';

afterEach(() => document.body.replaceChildren());

/** The question a dropped file's name asks, opened from a button that had the focus. */
function asked() {
  const opener = document.body.appendChild(document.createElement('button'));
  opener.focus();
  const onanswer = vi.fn();
  render(AskDialog, {
    props: {
      title: '“lid.kup” is in parts already',
      text: 'Replace it with yours, or add yours as “lid 2.kup”?',
      answers: [
        { text: 'Cancel', value: 'cancel' },
        { text: 'Replace', value: 'replace' },
        { text: 'Rename', value: 'rename', primary: true },
      ],
      cancel: 'cancel',
      onanswer,
    },
  });
  return { opener, onanswer, dialog: screen.getByRole('dialog') };
}

describe('a question', () => {
  it('asks in a modal dialog, an answer a button each, the primary one focused', () => {
    const { dialog } = asked();
    expect(/** @type {HTMLDialogElement} */ (dialog).open).toBe(true);
    expect(screen.getByRole('dialog', { name: '“lid.kup” is in parts already' })).toBe(dialog);
    expect(
      document.getElementById(/** @type {string} */ (dialog.getAttribute('aria-describedby')))
        ?.textContent,
    ).toBe('Replace it with yours, or add yours as “lid 2.kup”?');
    const buttons = within(dialog).getAllByRole('button');
    expect(buttons.map((button) => button.textContent?.trim())).toEqual([
      'Cancel',
      'Replace',
      'Rename',
    ]);
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Rename' }));
  });

  it('gives the answer chosen once, closed, the focus back where it was', async () => {
    const { opener, onanswer, dialog } = asked();
    const rename = screen.getByRole('button', { name: 'Rename' });
    await fireEvent.click(screen.getByRole('button', { name: 'Replace' }));
    await fireEvent.click(rename);
    expect(onanswer.mock.calls).toEqual([['replace']]);
    expect(/** @type {HTMLDialogElement} */ (dialog).open).toBe(false);
    expect(document.activeElement).toBe(opener);
  });

  it('answers its cancel to Escape, or to the browser cancelling it', async () => {
    const first = asked();
    await fireEvent.keyDown(first.dialog, { key: 'Escape' });
    expect(first.onanswer.mock.calls).toEqual([['cancel']]);
    document.body.replaceChildren();
    const second = asked();
    const cancelled = new Event('cancel', { cancelable: true });
    second.dialog.dispatchEvent(cancelled);
    expect([cancelled.defaultPrevented, second.onanswer.mock.calls]).toEqual([true, [['cancel']]]);
  });
});
