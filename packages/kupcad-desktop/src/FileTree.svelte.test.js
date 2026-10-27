import { fireEvent, render, screen } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';
import FileTree from './FileTree.svelte';

/** @import { Entry } from './folder.js' */

/** @type {Entry[]} */
const ENTRIES = [
  { kind: 'folder', name: 'parts', path: '/w/parts', depth: 0 },
  { kind: 'folder', name: 'brackets', path: '/w/parts/brackets', depth: 1 },
  { kind: 'script', name: 'l.kup', path: '/w/parts/brackets/l.kup', depth: 2 },
  { kind: 'data', name: 'l.stl', path: '/w/parts/brackets/l.stl', depth: 2 },
  { kind: 'script', name: 'lid.kup', path: '/w/parts/lid.kup', depth: 1 },
  { kind: 'script', name: 'b.kup', path: '/w/b.kup', depth: 0 },
];

/** The tree of ENTRIES with the folders `closed` closed, and what it was told. */
function treeOf(/** @type {string[]} */ closed = []) {
  const props = {
    entries: ENTRIES,
    collapsed: new Set(closed),
    selected: null,
    unsaved: new Set(),
    onopen: vi.fn(),
    ontoggle: vi.fn(),
  };
  render(FileTree, { props });
  return props;
}

const shown = () => screen.getAllByRole('listitem').map((row) => row.textContent?.trim());
const row = (/** @type {string} */ name) => screen.getByRole('button', { name });

describe('the tree', () => {
  it('shows each folder open, with all that is in it', () => {
    treeOf();
    expect(shown()).toEqual(['▾parts', '▾brackets', 'l.kup', 'l.stl', 'lid.kup', 'b.kup']);
    expect(row('parts').getAttribute('aria-expanded')).toBe('true');
  });

  it('shows nothing under a closed folder, its folders included', () => {
    treeOf(['/w/parts']);
    expect(shown()).toEqual(['▸parts', 'b.kup']);
    expect(row('parts').getAttribute('aria-expanded')).toBe('false');
  });

  it('opens a closed folder clicked, and closes an open one', async () => {
    const tree = treeOf(['/w/parts/brackets']);
    await fireEvent.click(row('brackets'));
    expect(tree.ontoggle).toHaveBeenLastCalledWith(ENTRIES[1], true);
    await fireEvent.click(row('parts'));
    expect(tree.ontoggle).toHaveBeenLastCalledWith(ENTRIES[0], false);
    expect(tree.onopen).not.toHaveBeenCalled();
  });

  it('opens a script clicked', async () => {
    const tree = treeOf();
    await fireEvent.click(row('lid.kup'));
    expect(tree.onopen).toHaveBeenCalledWith(ENTRIES[4]);
    expect(tree.ontoggle).not.toHaveBeenCalled();
  });
});

describe("the tree's keys", () => {
  it('move up and down its rows, past what has none to open', async () => {
    treeOf();
    row('brackets').focus();
    await fireEvent.keyDown(row('brackets'), { key: 'ArrowDown' });
    expect(document.activeElement).toBe(row('l.kup'));
    // l.stl is data: nothing to open, so no row to stop at
    await fireEvent.keyDown(row('l.kup'), { key: 'ArrowDown' });
    expect(document.activeElement).toBe(row('lid.kup'));
    await fireEvent.keyDown(row('lid.kup'), { key: 'ArrowUp' });
    expect(document.activeElement).toBe(row('l.kup'));
  });

  it('open a closed folder with the right arrow, then go into it', async () => {
    const tree = treeOf(['/w/parts/brackets']);
    row('brackets').focus();
    await fireEvent.keyDown(row('brackets'), { key: 'ArrowRight' });
    expect(tree.ontoggle).toHaveBeenCalledWith(ENTRIES[1], true);
    row('parts').focus();
    await fireEvent.keyDown(row('parts'), { key: 'ArrowRight' });
    expect(document.activeElement).toBe(row('brackets'));
  });

  it('close an open folder with the left arrow, and go out of a closed one or a script', async () => {
    const tree = treeOf(['/w/parts/brackets']);
    row('parts').focus();
    await fireEvent.keyDown(row('parts'), { key: 'ArrowLeft' });
    expect(tree.ontoggle).toHaveBeenCalledWith(ENTRIES[0], false);
    row('brackets').focus();
    await fireEvent.keyDown(row('brackets'), { key: 'ArrowLeft' });
    expect(document.activeElement).toBe(row('parts'));
    row('lid.kup').focus();
    await fireEvent.keyDown(row('lid.kup'), { key: 'ArrowLeft' });
    expect(document.activeElement).toBe(row('parts'));
    expect(tree.ontoggle).toHaveBeenCalledOnce();
  });

  it('leave the keys it has no use for to the page', async () => {
    treeOf();
    row('b.kup').focus();
    const enter = new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true });
    row('b.kup').dispatchEvent(enter);
    expect(enter.defaultPrevented).toBe(false);
  });
});
