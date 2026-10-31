import { createEvent, fireEvent, render, screen, within } from '@testing-library/svelte';
import { describe, expect, it, vi } from 'vitest';
import FileTree from './FileTree.svelte';

/** @import { Entry } from './tree.js' */

/** @type {Entry[]} */
const ENTRIES = [
  { kind: 'folder', name: 'parts', path: '/w/parts', depth: 0 },
  { kind: 'folder', name: 'brackets', path: '/w/parts/brackets', depth: 1 },
  { kind: 'script', name: 'l.kup', path: '/w/parts/brackets/l.kup', depth: 2 },
  { kind: 'data', name: 'l.stl', path: '/w/parts/brackets/l.stl', depth: 2 },
  { kind: 'script', name: 'lid.kup', path: '/w/parts/lid.kup', depth: 1 },
  { kind: 'script', name: 'b.kup', path: '/w/b.kup', depth: 0 },
];

/**
 * The tree of ENTRIES with the folders `closed` closed, and what it was told.
 * @param {string[]} [closed]
 * @param {Partial<import('svelte').ComponentProps<typeof FileTree>>} [more]
 */
function treeOf(closed = [], more = {}) {
  const told = {
    onopen: vi.fn(),
    ontoggle: vi.fn(),
    oncommit: vi.fn(),
    oncancel: vi.fn(),
    onmenu: vi.fn(),
    onrename: vi.fn(),
    ontrash: vi.fn(),
    onnew: vi.fn(),
  };
  const props = {
    entries: ENTRIES,
    collapsed: new Set(closed),
    selected: null,
    unsaved: new Set(),
    root: '/w',
    ...told,
    ...more,
  };
  const { rerender } = render(FileTree, { props });
  return { ...told, rerender };
}

const shown = () =>
  within(screen.getByRole('list'))
    .getAllByRole('listitem')
    .map((row) => row.textContent?.trim());
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

describe("the tree's bar", () => {
  it('makes a script or a folder, its shortcuts the tooltips', async () => {
    const tree = treeOf([], { keys: { script: '⌘N', folder: '⇧⌘N' } });
    expect(screen.getByText('Files')).toBeTruthy();
    await fireEvent.click(screen.getByRole('button', { name: 'New script' }));
    await fireEvent.click(screen.getByRole('button', { name: 'New folder' }));
    expect(tree.onnew.mock.calls).toEqual([['script'], ['folder']]);
    expect(screen.getByRole('button', { name: 'New script' }).title).toBe('New script (⌘N)');
    expect(screen.getByRole('button', { name: 'New folder' }).title).toBe('New folder (⇧⌘N)');
  });

  it('has its title alone for a host that makes nothing', () => {
    treeOf([], { onnew: undefined, title: 'Project' });
    expect(screen.getByText('Project')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'New script' })).toBeNull();
  });
});

it("opens a file the host opens besides scripts, the others' rows nothing to click", async () => {
  const tree = treeOf([], { opens: (/** @type {Entry} */ entry) => entry.name.endsWith('.stl') });
  await fireEvent.click(row('l.stl'));
  expect(tree.onopen).toHaveBeenCalledWith(ENTRIES[3]);
  // By default a data file's row is no button
  document.body.replaceChildren();
  treeOf();
  expect(screen.queryByRole('button', { name: 'l.stl' })).toBeNull();
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

describe("the tree's own menus and keys", () => {
  it("gives a row's menu, and the tree's, in place of the page's, where the pointer is", async () => {
    const tree = treeOf();
    const right = new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 40,
      clientY: 90,
    });
    row('lid.kup').dispatchEvent(right);
    expect(right.defaultPrevented).toBe(true);
    expect(tree.onmenu).toHaveBeenCalledExactlyOnceWith(ENTRIES[4], { x: 40, y: 90 });
    // A data file has no button, its row a menu all the same
    await fireEvent.contextMenu(screen.getByText('l.stl'));
    expect(tree.onmenu).toHaveBeenLastCalledWith(ENTRIES[3], { x: 0, y: 0 });
    await fireEvent.contextMenu(screen.getByRole('list'));
    expect(tree.onmenu).toHaveBeenLastCalledWith(null, { x: 0, y: 0 });
    expect(tree.onmenu).toHaveBeenCalledTimes(3);
  });

  it('renames a row with F2, moves it to the trash with Delete or ⌘⌫, and gives its menu by the keys', async () => {
    const tree = treeOf();
    row('b.kup').focus();
    await fireEvent.keyDown(row('b.kup'), { key: 'F2' });
    expect(tree.onrename).toHaveBeenCalledWith(ENTRIES[5]);
    await fireEvent.keyDown(row('b.kup'), { key: 'Delete' });
    row('parts').focus();
    await fireEvent.keyDown(row('parts'), { key: 'Backspace', metaKey: true });
    row('b.kup').focus();
    expect(tree.ontrash.mock.calls).toEqual([[ENTRIES[5]], [ENTRIES[0]]]);
    // Backspace alone is nothing to it
    await fireEvent.keyDown(row('b.kup'), { key: 'Backspace' });
    expect(tree.ontrash).toHaveBeenCalledTimes(2);
    row('b.kup').getBoundingClientRect = () => /** @type {DOMRect} */ ({ left: 20, bottom: 82 });
    await fireEvent.keyDown(row('b.kup'), { key: 'F10', shiftKey: true });
    await fireEvent.keyDown(row('b.kup'), { key: 'ContextMenu' });
    // Under the row
    const under = { x: 20, y: 82 };
    expect(tree.onmenu.mock.calls).toEqual([
      [ENTRIES[5], under],
      [ENTRIES[5], under],
    ]);
  });
});

/** The field a name is given in. */
const field = () => /** @type {HTMLInputElement} */ (screen.getByRole('textbox'));

describe('a name given in the tree', () => {
  it('renames a row in its place, its name without its extension chosen: Enter gives it', async () => {
    const tree = treeOf([], { editing: { path: '/w/parts/lid.kup' } });
    expect(screen.queryByRole('button', { name: 'lid.kup' })).toBeNull();
    expect(field().getAttribute('aria-label')).toBe('Rename lid.kup');
    expect(document.activeElement).toBe(field());
    expect([field().selectionStart, field().selectionEnd]).toEqual([0, 3]);
    await fireEvent.input(field(), { target: { value: 'cover.kup' } });
    await fireEvent.keyDown(field(), { key: 'Enter' });
    expect(tree.oncommit).toHaveBeenCalledExactlyOnceWith('cover.kup');
  });

  it('is left with Escape, and nothing given as the field goes', async () => {
    const tree = treeOf([], { editing: { path: '/w/b.kup' } });
    await fireEvent.input(field(), { target: { value: 'c.kup' } });
    await fireEvent.keyDown(field(), { key: 'Escape' });
    await fireEvent.blur(field());
    expect(tree.oncancel).toHaveBeenCalledOnce();
    expect(tree.oncommit).not.toHaveBeenCalled();
  });

  it('is given as the field is left, and none where it is empty or the same', async () => {
    const tree = treeOf([], { editing: { path: '/w/b.kup' } });
    await fireEvent.blur(field());
    expect(tree.oncancel).toHaveBeenCalledOnce();
    await tree.rerender({ editing: { in: '/w/parts', kind: 'folder' } });
    await fireEvent.input(field(), { target: { value: 'covers' } });
    await fireEvent.blur(field());
    expect(tree.oncommit).toHaveBeenCalledExactlyOnceWith('covers');
  });

  it("makes a new entry's field in its folder, under the folder's row, or at the tree's top", async () => {
    const tree = treeOf([], { editing: { in: '/w/parts/brackets', kind: 'script' } });
    expect(shown()).toEqual(['▾parts', '▾brackets', '', 'l.kup', 'l.stl', 'lid.kup', 'b.kup']);
    expect(field().getAttribute('aria-label')).toBe('New script name');
    expect(field().closest('li')?.style.paddingLeft).toBe('32px');
    await tree.rerender({ editing: { in: '/w', kind: 'folder' } });
    expect(shown()[0]).toBe('');
    expect(field().getAttribute('aria-label')).toBe('New folder name');
  });

  it('says what is wrong with a name refused, the field kept to put it right', async () => {
    treeOf([], { editing: { in: '/w', kind: 'script' }, problem: 'b.kup is there already.' });
    expect(field().getAttribute('aria-invalid')).toBe('true');
    const said = document.getElementById(
      /** @type {string} */ (field().getAttribute('aria-describedby')),
    );
    expect(said?.textContent).toBe('b.kup is there already.');
  });
});

/** A drag from the system's file manager, of `files`. @param {File[]} [files] */
const dragging = (files = []) => ({
  dataTransfer: { types: ['Files'], files, dropEffect: 'none' },
});
/** Whether the row named `name` is marked as where files dragged would go. @param {string} name */
const marked = (name) => row(name).closest('li')?.classList.contains('dropping');
const tree = () => screen.getByRole('list');

describe('files dropped on the tree', () => {
  it("go in a folder's row's own folder, the one a file's row is in, or the root", async () => {
    const ondropfiles = vi.fn();
    treeOf([], { ondropfiles });
    const lid = new File(['cube(1)'], 'lid.kup');
    for (const target of [
      row('brackets'),
      row('lid.kup'),
      screen.getByText('l.stl'),
      row('b.kup'),
      tree(),
    ]) {
      await fireEvent.drop(target, dragging([lid]));
    }
    expect(ondropfiles.mock.calls).toEqual([
      [[lid], '/w/parts/brackets'],
      [[lid], '/w/parts'],
      [[lid], '/w/parts/brackets'],
      [[lid], '/w'],
      [[lid], '/w'],
    ]);
  });

  it('mark the folder they would go in while they are over it, the whole tree for the root', async () => {
    treeOf([], { ondropfiles: vi.fn() });
    expect(await fireEvent.dragOver(row('l.kup'), dragging())).toBe(false);
    expect([marked('brackets'), marked('parts')]).toEqual([true, false]);
    await fireEvent.dragOver(row('b.kup'), dragging());
    expect([marked('brackets'), tree().classList.contains('dropping')]).toEqual([false, true]);
    // From row to row, still over the tree; then off it
    const between = createEvent.dragLeave(row('b.kup'));
    Object.defineProperty(between, 'relatedTarget', { value: row('parts') });
    await fireEvent(row('b.kup'), between);
    expect(tree().classList.contains('dropping')).toBe(true);
    await fireEvent.dragLeave(tree());
    expect(tree().classList.contains('dropping')).toBe(false);
  });

  it('are taken by no tree without a host for them, and a drag of text by none', async () => {
    treeOf();
    expect(await fireEvent.dragOver(row('b.kup'), dragging())).toBe(true);
    document.body.replaceChildren();
    treeOf([], { ondropfiles: vi.fn() });
    const words = { dataTransfer: { types: ['text/plain'], files: [], dropEffect: 'none' } };
    expect(await fireEvent.dragOver(row('b.kup'), words)).toBe(true);
    expect(tree().classList.contains('dropping')).toBe(false);
  });
});
