import { expect, it, vi } from 'vitest';
import { rowMenu } from './menu.js';

/** @import { MenuItem } from './menu.js' */
/** @import { Entry } from './tree.js' */

/** A menu's items' texts, its separators as they are. */
const texts = (/** @type {MenuItem[]} */ menu) =>
  menu.map((entry) => (entry === '-' ? entry : entry.text));

/** @type {Entry} */
const SCRIPT = { kind: 'script', name: 'a.kup', path: '/w/a.kup', depth: 0 };
/** @type {Entry} */
const FOLDER = { kind: 'folder', name: 'parts', path: '/w/parts', depth: 0 };

it("offers a tree's row what it can do, and the tree itself what can be made", () => {
  const does = { newScript: vi.fn(), newFolder: vi.fn(), rename: vi.fn(), remove: vi.fn() };
  expect(texts(rowMenu(null, does))).toEqual(['New Script', 'New Folder']);
  const row = rowMenu(SCRIPT, does, { remove: 'Move to Trash' });
  expect(texts(row)).toEqual(['New Script', 'New Folder', '-', 'Rename…', 'Move to Trash']);
  for (const entry of row) if (entry !== '-') entry.action();
  expect(Object.values(does).map((action) => action.mock.calls.length)).toEqual([1, 1, 1, 1]);
});

it("offers a browser's uploads in any folder, and a file's download, a folder's none", () => {
  const does = {
    newScript: vi.fn(),
    newFolder: vi.fn(),
    rename: vi.fn(),
    remove: vi.fn(),
    upload: vi.fn(),
    download: vi.fn(),
  };
  expect(texts(rowMenu(null, does))).toEqual(['New Script', 'New Folder', 'Upload Files…']);
  expect(texts(rowMenu(SCRIPT, does))).toEqual([
    'New Script',
    'New Folder',
    'Upload Files…',
    '-',
    'Download',
    'Rename…',
    'Delete…',
  ]);
  expect(texts(rowMenu(FOLDER, does))).not.toContain('Download');
});
