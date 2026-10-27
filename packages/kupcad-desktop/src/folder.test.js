import { describe, expect, it, vi } from 'vitest';
import {
  changesTree,
  childPath,
  fileUri,
  foldersAbove,
  kindOf,
  listFolder,
  MAX_ENTRIES,
  pickFolder,
  shownEntries,
  WATCH_DELAY_MS,
  watchFolder,
} from './folder.js';

/** @import { Entry } from './folder.js' */
/** @import { WatchEvent } from '@tauri-apps/plugin-fs' */

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

  it('lists folders in folders, however deep, and leaves out one with nothing in it', async () => {
    const fs = readerOf({
      '/w': ['parts/', 'b.kup'],
      '/w/parts': ['brackets/', 'empty/', 'lid.kup'],
      '/w/parts/brackets': ['corner/', 'l.kup'],
      '/w/parts/brackets/corner': ['c.kup', 'c.stl'],
      '/w/parts/empty': ['notes.txt'],
    });
    const entries = await listFolder('/w', fs);
    expect(entries.map(({ kind, name, depth }) => `${'  '.repeat(depth)}${kind} ${name}`)).toEqual([
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

/**
 * A change the watcher reports.
 * @param {WatchEvent['type']} type
 * @param {string[]} [paths]
 * @returns {WatchEvent}
 */
const event = (type, paths = ['/w/parts/new.kup']) => ({ type, paths, attrs: null });

describe('a change the watcher reports', () => {
  it('changes the tree when an entry is made, removed or renamed, or the system says no more', () => {
    for (const type of /** @type {WatchEvent['type'][]} */ ([
      { create: { kind: 'file' } },
      { create: { kind: 'folder' } },
      { remove: { kind: 'any' } },
      { modify: { kind: 'rename', mode: 'both' } },
      { modify: { kind: 'any' } },
      'any',
      'other',
    ])) {
      expect(changesTree(event(type), '/w')).toBe(true);
    }
  });

  it("doesn't when a file is only read, or written in place as a save is", () => {
    for (const type of /** @type {WatchEvent['type'][]} */ ([
      { access: { kind: 'open', mode: 'read' } },
      { access: { kind: 'close', mode: 'write' } },
      { modify: { kind: 'data', mode: 'content' } },
      { modify: { kind: 'metadata', mode: 'write-time' } },
    ])) {
      expect(changesTree(event(type), '/w')).toBe(false);
    }
  });

  it('is passed over in the folders the tree leaves out, and for a hidden file', () => {
    const create = { create: { kind: /** @type {const} */ ('file') } };
    expect(changesTree(event(create, ['/w/.git/index.lock']), '/w')).toBe(false);
    expect(changesTree(event(create, ['/w/parts/node_modules/x/a.json']), '/w')).toBe(false);
    expect(changesTree(event(create, ['/w/.git']), '/w')).toBe(false);
    expect(changesTree(event(create, ['/w/.DS_Store']), '/w')).toBe(false);
    // Any one path the tree may show is enough
    expect(changesTree(event(create, ['/w/.git/HEAD', '/w/b.kup']), '/w')).toBe(true);
    // A folder named like a skipped one above the root is the root's own business
    expect(changesTree(event(create, ['/target/w/b.kup']), '/target/w')).toBe(true);
    // The system's real path for a file in the root may not start with it: it may be anything
    expect(changesTree(event(create, ['/private/w/.git/HEAD']), '/w')).toBe(true);
  });
});

it('watches everything under the folder, telling only of what may change its tree', async () => {
  const stop = vi.fn();
  const watch = vi.fn(
    /** @type {typeof import('@tauri-apps/plugin-fs').watch} */ (async () => stop),
  );
  const onchange = vi.fn();
  const unwatch = await watchFolder('/w', onchange, { watch });
  expect(watch).toHaveBeenCalledWith('/w', expect.any(Function), {
    recursive: true,
    delayMs: WATCH_DELAY_MS,
  });
  const report = watch.mock.calls[0][1];
  report(event({ modify: { kind: 'data', mode: 'content' } }, ['/w/b.kup']));
  expect(onchange).not.toHaveBeenCalled();
  report(event({ create: { kind: 'file' } }, ['/w/c.kup']));
  expect(onchange).toHaveBeenCalledOnce();
  unwatch();
  expect(stop).toHaveBeenCalledOnce();
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
