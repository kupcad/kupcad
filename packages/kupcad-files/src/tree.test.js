import { describe, expect, it } from 'vitest';
import {
  childPath,
  foldersAbove,
  kindOf,
  languageOf,
  listFolder,
  MAX_ENTRIES,
  nameOf,
  nameProblem,
  parentOf,
  renamedName,
  scriptName,
  shownEntries,
  within,
} from './tree.js';

/** @import { Entry } from './tree.js' */

/**
 * A stand-in for the host's `readDir`: each folder's entries by its path, a name ending in `/`
 * a folder.
 * @param {Record<string, string[]>} tree
 */
function readerOf(tree) {
  return {
    readDir: async (/** @type {string} */ dir) =>
      (tree[dir] ?? []).map((name) => ({
        name: name.replace(/\/$/, ''),
        isDirectory: name.endsWith('/'),
        isFile: !name.endsWith('/'),
        isSymlink: false,
      })),
  };
}

/** Each entry as `kind name`, indented by its depth. */
const outline = (/** @type {Entry[]} */ entries) =>
  entries.map(({ kind, name, depth }) => `${'  '.repeat(depth)}${kind} ${name}`);

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
    expect(outline(entries)).toEqual([
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

  it('lists folders in folders, however deep, and leaves out one with nothing listed in it', async () => {
    const fs = readerOf({
      '/w': ['parts/', 'b.kup'],
      '/w/parts': ['brackets/', 'notes/', 'lid.kup'],
      '/w/parts/brackets': ['corner/', 'l.kup'],
      '/w/parts/brackets/corner': ['c.kup', 'c.stl'],
      '/w/parts/notes': ['todo.txt'],
    });
    const entries = await listFolder('/w', fs);
    expect(outline(entries)).toEqual([
      'folder parts',
      '  folder brackets',
      '    folder corner',
      '      script c.kup',
      '      data c.stl',
      '    script l.kup',
      '  script lid.kup',
      'script b.kup',
    ]);
    expect(entries[3].path).toBe('/w/parts/brackets/corner/c.kup');
  });

  it('lists an empty folder, as one just made is, and the folder it is in', async () => {
    const fs = readerOf({ '/': ['parts/', 'a.kup'], '/parts': ['covers/'], '/parts/covers': [] });
    const entries = await listFolder('/', fs);
    expect(outline(entries)).toEqual(['folder parts', '  folder covers', 'script a.kup']);
    expect(entries.map((entry) => entry.path)).toEqual(['/parts', '/parts/covers', '/a.kup']);
  });

  it(`stops at ${MAX_ENTRIES} entries: a folder with more is no project`, async () => {
    const many = Array.from({ length: MAX_ENTRIES + 10 }, (_, i) => `p${i}.kup`);
    expect(await listFolder('/w', readerOf({ '/w': many }))).toHaveLength(MAX_ENTRIES);
  });
});

/** A tree of folders in folders, as listFolder gives it. @type {Entry[]} */
const NESTED = [
  { kind: 'folder', name: 'parts', path: '/w/parts', depth: 0 },
  { kind: 'folder', name: 'brackets', path: '/w/parts/brackets', depth: 1 },
  { kind: 'script', name: 'l.kup', path: '/w/parts/brackets/l.kup', depth: 2 },
  { kind: 'data', name: 'l.stl', path: '/w/parts/brackets/l.stl', depth: 2 },
  { kind: 'script', name: 'lid.kup', path: '/w/parts/lid.kup', depth: 1 },
  { kind: 'folder', name: 'tools', path: '/w/tools', depth: 0 },
  { kind: 'script', name: 'jig.kup', path: '/w/tools/jig.kup', depth: 1 },
  { kind: 'script', name: 'b.kup', path: '/w/b.kup', depth: 0 },
];
const names = (/** @type {Entry[]} */ entries) => entries.map((entry) => entry.name);

describe('the tree shown', () => {
  it('is all of it with no folder closed', () => {
    expect(shownEntries(NESTED, new Set())).toEqual(NESTED);
  });

  it("leaves out everything under a closed folder, its folders' too, and nothing after it", () => {
    expect(names(shownEntries(NESTED, new Set(['/w/parts'])))).toEqual([
      'parts',
      'tools',
      'jig.kup',
      'b.kup',
    ]);
    expect(names(shownEntries(NESTED, new Set(['/w/parts/brackets', '/w/tools'])))).toEqual([
      'parts',
      'brackets',
      'lid.kup',
      'tools',
      'b.kup',
    ]);
  });

  it('keeps a folder closed inside a closed one closed when that one opens', () => {
    const closed = new Set(['/w/parts', '/w/parts/brackets']);
    expect(names(shownEntries(NESTED, closed))).not.toContain('l.kup');
    closed.delete('/w/parts');
    expect(names(shownEntries(NESTED, closed))).toEqual([
      'parts',
      'brackets',
      'lid.kup',
      'tools',
      'jig.kup',
      'b.kup',
    ]);
  });
});

describe('the folders an entry is in', () => {
  it('are those above it, the outermost first', () => {
    expect(foldersAbove(NESTED, '/w/parts/brackets/l.kup')).toEqual([
      '/w/parts',
      '/w/parts/brackets',
    ]);
    expect(foldersAbove(NESTED, '/w/parts/lid.kup')).toEqual(['/w/parts']);
    expect(foldersAbove(NESTED, '/w/tools/jig.kup')).toEqual(['/w/tools']);
  });

  it("are none at the top, or for one the tree doesn't hold", () => {
    expect(foldersAbove(NESTED, '/w/b.kup')).toEqual([]);
    expect(foldersAbove(NESTED, '/w/parts')).toEqual([]);
    expect(foldersAbove(NESTED, '/w/gone.kup')).toEqual([]);
  });
});

describe('a new entry', () => {
  it('is named as any system takes, and not hidden', () => {
    expect(nameProblem('part 2.kup')).toBeNull();
    expect(nameProblem('ünit')).toBeNull();
    for (const name of ['', '  ', ' a', 'a ', 'a/b', 'a\\b', 'a:b', 'a?', '.hidden', 'a\u0007']) {
      expect([name, nameProblem(name)]).not.toEqual([name, null]);
    }
  });

  it('is a script by its extension, given it where it has none', () => {
    expect([scriptName('part'), scriptName('part.kup'), scriptName('part.KUP')]).toEqual([
      'part.kup',
      'part.kup',
      'part.KUP',
    ]);
    expect(scriptName('notes.txt')).toBe('notes.txt.kup');
  });

  it("is in a folder, which a path under it is within and a sibling's isn't", () => {
    expect([parentOf('/w/parts/a.kup'), parentOf('/w'), parentOf('C:\\w\\a.kup')]).toEqual([
      '/w/parts',
      '/',
      'C:\\w',
    ]);
    expect([within('/w/p', '/w/p'), within('/w/p/a.kup', '/w/p'), within('/w/pq', '/w/p')]).toEqual(
      [true, true, false],
    );
  });

  it("keeps a data file's extension renamed to a name the tree wouldn't show", () => {
    /** @type {Entry} */
    const stl = { kind: 'data', name: 'lid.stl', path: '/w/lid.stl', depth: 0 };
    expect([
      renamedName(stl, 'cover'),
      renamedName(stl, 'cover.obj'),
      renamedName(stl, 'a.txt'),
    ]).toEqual(['cover.stl', 'cover.obj', 'a.txt.stl']);
    expect(renamedName({ ...stl, kind: 'script', name: 'a.kup' }, 'b')).toBe('b.kup');
    expect(renamedName({ ...stl, kind: 'folder', name: 'parts' }, 'bits.kup')).toBe('bits.kup');
  });

  it('is known by its last name, a root by none', () => {
    expect(['/w/parts/a.kup', 'C:\\w\\a.kup', '/w', '/', 'a.kup'].map(nameOf)).toEqual([
      'a.kup',
      'a.kup',
      'w',
      '',
      'a.kup',
    ]);
  });

  it("has a root for its folder with the root's separator: /, or a drive", () => {
    expect([parentOf('/a.kup'), parentOf('C:\\a.kup'), parentOf('C:\\w\\a.kup')]).toEqual([
      '/',
      'C:\\',
      'C:\\w',
    ]);
    // A name alone is in no folder, and nothing is within that
    expect([parentOf('a.kup'), within('a.kup', ''), within('', '')]).toEqual(['', false, false]);
  });

  it('is within the root, whose path ends with its separator', () => {
    expect([within('/a.kup', '/'), within('/parts/a.kup', '/'), within('/', '/')]).toEqual([
      true,
      true,
      true,
    ]);
    expect([within('C:\\w\\a.kup', 'C:\\'), within('/a.kup', '/b/')]).toEqual([true, false]);
  });
});

describe('a file', () => {
  it('is a script, data a script reads, or nothing to KupCAD, by its extension', () => {
    expect(['a.kup', 'mesh.stl', 'part.STEP', 'f.otf', 'kup', '.kup', 'a.png'].map(kindOf)).toEqual(
      ['script', 'data', 'data', 'data', null, null, null],
    );
  });

  it("is listed as data where it is a package's lockfile, JSON though its extension isn't", () => {
    expect(['kupcad.lock', 'yarn.lock', 'kupcad.json'].map(kindOf)).toEqual(['data', null, 'data']);
  });

  it('is opened as a script, as JSON, or not at all as text', () => {
    expect(
      ['a.kup', 'kupcad.json', 'sizes.JSON', 'kupcad.lock', 'mesh.stl', 'notes.txt'].map(
        languageOf,
      ),
    ).toEqual(['kupcad', 'json', 'json', 'json', null, null]);
  });

  it("is in its folder with the folder's separator", () => {
    expect(childPath('/w', 'a.kup')).toBe('/w/a.kup');
    expect(childPath('/w/', 'a.kup')).toBe('/w/a.kup');
    expect(childPath('/', 'a.kup')).toBe('/a.kup');
    expect(childPath('C:\\w', 'a.kup')).toBe('C:\\w\\a.kup');
  });
});
