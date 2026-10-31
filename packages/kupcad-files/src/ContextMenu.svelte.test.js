import { fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import ContextMenu from './ContextMenu.svelte';

/** @import { MenuItem } from './menu.js' */

afterEach(() => {
  vi.restoreAllMocks();
  document.body.replaceChildren();
});

/**
 * A menu of Rename, a separator and Delete, opened at `at` from a button that had the focus.
 * @param {{ x: number, y: number }} [at]
 */
function menuAt(at = { x: 30, y: 40 }) {
  const opener = document.body.appendChild(document.createElement('button'));
  opener.focus();
  const rename = vi.fn();
  const remove = vi.fn();
  const onclose = vi.fn();
  /** @type {MenuItem[]} */
  const items = [{ text: 'Rename…', action: rename }, '-', { text: 'Delete…', action: remove }];
  render(ContextMenu, { props: { items, at, onclose, label: 'a.kup' } });
  return { opener, rename, remove, onclose, menu: screen.getByRole('menu') };
}

const item = (/** @type {string} */ name) => screen.getByRole('menuitem', { name });
/** The browser's toggle event, said a moment after a popover hides. */
const toggled = () => new Promise((done) => setTimeout(done));

describe('a context menu', () => {
  it('opens where it is asked, its items and separators in order, the first focused', () => {
    const { menu } = menuAt();
    expect(menu.dataset.shown).toBe('true');
    expect(menu.getAttribute('aria-label')).toBe('a.kup');
    expect([menu.style.left, menu.style.top]).toEqual(['30px', '40px']);
    expect(screen.getAllByRole('menuitem').map((button) => button.textContent?.trim())).toEqual([
      'Rename…',
      'Delete…',
    ]);
    expect(screen.getAllByRole('separator')).toHaveLength(1);
    expect(document.activeElement).toBe(item('Rename…'));
  });

  it('is moved in to stay in the window', () => {
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue(
      /** @type {DOMRect} */ ({ width: 200, height: 100 }),
    );
    const { menu } = menuAt({ x: innerWidth - 50, y: innerHeight + 10 });
    expect([menu.style.left, menu.style.top]).toEqual([
      `${innerWidth - 200}px`,
      `${innerHeight - 100}px`,
    ]);
  });

  it('moves between its items with the arrows, Home and End, round from end to end', async () => {
    menuAt();
    await fireEvent.keyDown(item('Rename…'), { key: 'ArrowDown' });
    expect(document.activeElement).toBe(item('Delete…'));
    await fireEvent.keyDown(item('Delete…'), { key: 'ArrowDown' });
    expect(document.activeElement).toBe(item('Rename…'));
    await fireEvent.keyDown(item('Rename…'), { key: 'ArrowUp' });
    expect(document.activeElement).toBe(item('Delete…'));
    await fireEvent.keyDown(item('Delete…'), { key: 'Home' });
    expect(document.activeElement).toBe(item('Rename…'));
    await fireEvent.keyDown(item('Rename…'), { key: 'End' });
    expect(document.activeElement).toBe(item('Delete…'));
  });

  it('does what an item chosen says, closed, the focus back where it was', async () => {
    const { opener, rename, remove, onclose, menu } = menuAt();
    await fireEvent.click(item('Delete…'));
    expect(remove).toHaveBeenCalledOnce();
    expect(rename).not.toHaveBeenCalled();
    expect(menu.dataset.shown).toBeUndefined();
    await toggled();
    expect(onclose).toHaveBeenCalledOnce();
    expect(document.activeElement).toBe(opener);
  });

  it('does nothing closed by the browser (Escape, a click elsewhere), the focus back', async () => {
    const { opener, rename, remove, onclose, menu } = menuAt();
    menu.hidePopover();
    await toggled();
    expect(onclose).toHaveBeenCalledOnce();
    expect([rename, remove].map((action) => action.mock.calls.length)).toEqual([0, 0]);
    expect(document.activeElement).toBe(opener);
  });

  it('closes as the focus leaves it, leaving the focus where it went', async () => {
    const { onclose, menu } = menuAt();
    const elsewhere = document.body.appendChild(document.createElement('input'));
    elsewhere.focus();
    expect(menu.dataset.shown).toBeUndefined();
    await toggled();
    expect(onclose).toHaveBeenCalledOnce();
    expect(document.activeElement).toBe(elsewhere);
  });
});
