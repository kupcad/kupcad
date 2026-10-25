import { describe, expect, it, vi } from 'vitest';
import { childPath, fileUri, kindOf, listFolder, MAX_ENTRIES, pickFolder } from './folder.js';

/**
 * A stand-in for the file system's `readDir`: each folder's entries by its path, a name ending
 * in `/` a folder.
 * @param {Record<string, string[]>} tree
 */
function readerOf(tree) {
  return {
    readDir: async (/** @type {string | URL} */ dir) =>
      (tree[String(dir)] ?? []).map((name) => ({
        name: name.replace(/\/$/, ''),
        isDirectory: name.endsWith('/'),
        isFile: !name.endsWith('/'),
        isSymlink: false,
      })),
  };
}

describe('listFolder', () => {
  it("lists the folder's scripts and data files as a tree, each folder's folders first", async () => {
    const fs = readerOf({
      '/w': ['README.md', 'part.kup', 'parts/', 'assets/', '.git/', '.kupcad/', 'notes/', 'a.kup'],
      '/w/parts': ['lid.kup', 'Bolt.KUP'],
      '/w/assets': ['logo.SVG', 'sizes.json', 'photo.png'],
      '/w/.kupcad': ['pkg/'],
      '/w/notes': ['todo.txt'],
    });
    const entries = await listFolder('/w', fs);
    expect(entries.map(({ kind, name, depth }) => `${'  '.repeat(depth)}${kind} ${name}`)).toEqual([
      'folder assets',
      '  data logo.SVG',
      '  data sizes.json',
      'folder parts',
      '  script Bolt.KUP',
      '  script lid.kup',
      'script a.kup',
      'script part.kup',
    ]);
    expect(entries[4].path).toBe('/w/parts/Bolt.KUP');
  });

  it(`stops at ${MAX_ENTRIES} entries: a folder with more is no project`, async () => {
    const many = Array.from({ length: MAX_ENTRIES + 10 }, (_, i) => `p${i}.kup`);
    expect(await listFolder('/w', readerOf({ '/w': many }))).toHaveLength(MAX_ENTRIES);
  });
});

describe('a file', () => {
  it('is a script, data a script reads, or nothing to the app, by its extension', () => {
    expect(['a.kup', 'mesh.stl', 'part.STEP', 'f.otf', 'kup', '.kup', 'a.png'].map(kindOf)).toEqual(
      ['script', 'data', 'data', 'data', null, null, null],
    );
  });

  it("is in its folder with the folder's separator", () => {
    expect(childPath('/w', 'a.kup')).toBe('/w/a.kup');
    expect(childPath('/w/', 'a.kup')).toBe('/w/a.kup');
    expect(childPath('C:\\w', 'a.kup')).toBe('C:\\w\\a.kup');
  });

  it('is known to the server by its file URI, each segment percent-encoded', () => {
    expect(fileUri('/w/my part #1.kup')).toBe('file:///w/my%20part%20%231.kup');
    expect(fileUri('/w/ünit.kup')).toBe('file:///w/%C3%BCnit.kup');
    expect(fileUri('C:\\w\\a.kup')).toBe('file:///C%3A/w/a.kup');
  });
});

it('picks a folder with what is under it, or none', async () => {
  const open = vi.fn().mockResolvedValueOnce('/w').mockResolvedValueOnce(null);
  expect(await pickFolder({ open })).toBe('/w');
  expect(open).toHaveBeenCalledWith(expect.objectContaining({ directory: true, recursive: true }));
  expect(await pickFolder({ open })).toBeNull();
});
