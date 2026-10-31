import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Project } from './project.svelte.js';

/** @import { Entry } from './tree.js' */

/** A promise a test resolves when it wants. */
function gate() {
  /** @type {((value?: unknown) => void) | undefined} */
  let open;
  const promise = new Promise((done) => (open = done));
  return { promise, resolve: () => open?.() };
}

/**
 * A project on a file system in memory, under `/w`: `files` by path (a folder's path ending
 * with `/`), which a test changes as another program would.
 * @param {Record<string, string>} files
 * @param {Partial<import('./project.svelte.js').ProjectOptions>} [options]
 */
function projectOn(files, options = {}) {
  const disk = new Map(Object.entries(files));
  const folders = new Set(
    [...disk.keys()].flatMap((path) => {
      const parts = path.split('/').slice(1, -1);
      return parts.map((_, i) => `/${parts.slice(0, i + 1).join('/')}`);
    }),
  );
  for (const path of disk.keys()) if (path.endsWith('/')) folders.add(path.slice(0, -1));
  const fs = {
    readDir: vi.fn(async (/** @type {string} */ dir) => {
      const names = new Set();
      const under = (/** @type {string} */ path) =>
        path.startsWith(`${dir}/`) ? path.slice(dir.length + 1).split('/')[0] : null;
      for (const path of [...disk.keys(), ...folders]) {
        const name = under(path);
        if (name) names.add(name);
      }
      return [...names].map((name) => {
        const isDirectory = folders.has(`${dir}/${name}`);
        return { name, isDirectory, isFile: !isDirectory };
      });
    }),
    read: vi.fn(async (/** @type {string} */ path) => {
      const text = disk.get(path);
      if (text === undefined) throw new Error(`no such file: ${path}`);
      return text;
    }),
    write: vi.fn(async (/** @type {string} */ path, /** @type {string} */ text) => {
      disk.set(path, text);
    }),
    writeBytes: vi.fn(async (/** @type {string} */ path, /** @type {Uint8Array} */ bytes) => {
      disk.set(path, new TextDecoder().decode(bytes));
    }),
    exists: vi.fn(async (/** @type {string} */ path) => disk.has(path) || folders.has(path)),
    mkdir: vi.fn(async (/** @type {string} */ path) => void folders.add(path)),
    rename: vi.fn(async (/** @type {string} */ from, /** @type {string} */ to) => {
      for (const [path, text] of Array.from(disk)) {
        if (path !== from && !path.startsWith(`${from}/`)) continue;
        disk.delete(path);
        disk.set(to + path.slice(from.length), text);
      }
      for (const folder of Array.from(folders)) {
        if (folder !== from && !folder.startsWith(`${from}/`)) continue;
        folders.delete(folder);
        folders.add(to + folder.slice(from.length));
      }
    }),
    remove: vi.fn(async (/** @type {string} */ path) => {
      for (const held of disk.keys())
        if (held === path || held.startsWith(`${path}/`)) disk.delete(held);
      for (const folder of folders)
        if (folder === path || folder.startsWith(`${path}/`)) folders.delete(folder);
    }),
  };
  const told = { onproblem: vi.fn(), onsave: vi.fn() };
  const project = new Project('/w', fs, { ...told, ...options });
  return { project, fs, disk, folders, ...told };
}

const FILES = {
  '/w/parts/lid.kup': 'cube(2)\n',
  '/w/parts/lid.stl': 'solid',
  '/w/a.kup': 'cube(1)\n',
};
const paths = (/** @type {Entry[]} */ entries) => entries.map((entry) => entry.path);

describe('a project', () => {
  it('lists its tree, one listing at a time, another after it for what changed meanwhile', async () => {
    const { project, fs, disk } = projectOn(FILES);
    const slow = gate();
    fs.readDir.mockImplementationOnce(async (dir) => {
      await slow.promise;
      return fs.readDir.getMockImplementation()?.(dir) ?? [];
    });
    const first = project.list();
    disk.set('/w/b.kup', '');
    const second = project.list();
    slow.resolve();
    await Promise.all([first, second]);
    expect(paths(project.entries)).toEqual([
      '/w/parts',
      '/w/parts/lid.kup',
      '/w/parts/lid.stl',
      '/w/a.kup',
      '/w/b.kup',
    ]);
    // The first listing, and the one after it
    expect(fs.readDir.mock.calls.filter(([dir]) => dir === '/w')).toHaveLength(2);
  });

  it('says a listing that failed', async () => {
    const { project, fs, onproblem } = projectOn(FILES);
    fs.readDir.mockRejectedValueOnce(new Error('gone'));
    expect(await project.list()).toBe(false);
    expect(onproblem).toHaveBeenCalledWith("w wasn't listed: gone");
  });

  it('opens and closes folders, and shows the folders a path is in', async () => {
    const { project } = projectOn({ ...FILES, '/w/parts/inner/x.kup': '' });
    await project.list();
    project.toggle('/w/parts', false);
    project.toggle('/w/parts/inner', false);
    expect([...project.collapsed]).toEqual(['/w/parts', '/w/parts/inner']);
    project.reveal('/w/parts/inner');
    expect(project.collapsed.size).toBe(0);
  });

  it("chooses the folder an entry is made in: a folder's own, a file's, the open file's, the root", async () => {
    const { project } = projectOn(FILES);
    await project.list();
    const [parts, lid] = project.entries;
    expect(project.folderFor(parts)).toBe('/w/parts');
    expect(project.folderFor(lid)).toBe('/w/parts');
    expect(project.folderFor(null, '/w/parts/lid.kup')).toBe('/w/parts');
    expect(project.folderFor(null)).toBe('/w');
  });
});

describe('a name given in the tree', () => {
  it('makes a script, empty, listed and given back; a folder too', async () => {
    const { project, disk, folders } = projectOn(FILES);
    await project.list();
    project.toggle('/w/parts', false);
    project.startNew('script', '/w/parts');
    expect([project.editing, project.collapsed.size]).toEqual([
      { in: '/w/parts', kind: 'script' },
      0,
    ]);
    const made = await project.commitName('cover');
    expect(made).toEqual({
      made: expect.objectContaining({ kind: 'script', path: '/w/parts/cover.kup', depth: 1 }),
    });
    expect([disk.get('/w/parts/cover.kup'), project.editing]).toEqual(['', null]);
    project.startNew('folder', '/w');
    expect(await project.commitName('bits')).toEqual({
      made: expect.objectContaining({ kind: 'folder', path: '/w/bits', depth: 0 }),
    });
    expect(folders.has('/w/bits')).toBe(true);
  });

  it('refuses a bad name, or one there already, the field kept', async () => {
    const { project, fs } = projectOn(FILES);
    await project.list();
    project.startNew('script', '/w');
    expect(await project.commitName('a/b')).toBeNull();
    expect(project.nameError).toMatch(/may not have/);
    expect(await project.commitName('a')).toBeNull();
    expect([project.nameError, project.editing]).toEqual([
      'a.kup is there already.',
      { in: '/w', kind: 'script' },
    ]);
    expect(fs.write).not.toHaveBeenCalled();
  });

  it('renames an entry, the scripts, closed folders and saves waiting in it following', async () => {
    const onsave = vi.fn();
    const { project, disk } = projectOn(
      { ...FILES, '/w/parts/inner/x.kup': '' },
      { onsave, saveAfterMs: () => 50 },
    );
    vi.useFakeTimers();
    try {
      await project.list();
      await project.scripts.read('/w/parts/lid.kup');
      project.edit('/w/parts/lid.kup', 'cube(3)\n');
      project.toggle('/w/parts/inner', false);
      project.startRename(/** @type {Entry} */ (project.entryAt('/w/parts')));
      const renamed = await project.commitName('pieces');
      expect(renamed).toEqual({ renamed: { from: '/w/parts', to: '/w/pieces' } });
      expect(disk.has('/w/pieces/lid.kup')).toBe(true);
      expect(project.scripts.text('/w/pieces/lid.kup')).toBe('cube(3)\n');
      expect([...project.collapsed]).toEqual(['/w/pieces/inner']);
      // The save that waited for the old path is off
      vi.advanceTimersByTime(100);
      expect(onsave).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps a data file's extension, and lets the host keep its editor before a rename", async () => {
    const beforeRename = vi.fn();
    const { project, disk } = projectOn(FILES, { beforeRename });
    await project.list();
    project.startRename(/** @type {Entry} */ (project.entryAt('/w/parts/lid.stl')));
    await project.commitName('cover');
    expect([disk.has('/w/parts/cover.stl'), beforeRename.mock.calls.length]).toEqual([true, 1]);
  });

  it('takes a rename to the same name in another case where the file system ignores case', async () => {
    const strict = projectOn({ ...FILES, '/w/A.kup': '' });
    await strict.project.list();
    strict.project.startRename(/** @type {Entry} */ (strict.project.entryAt('/w/a.kup')));
    expect(await strict.project.commitName('A')).toBeNull();
    expect(strict.project.nameError).toBe('A.kup is there already.');
    const lax = projectOn(FILES, { ignoresCase: true });
    await lax.project.list();
    lax.disk.set('/w/A.kup', 'x');
    lax.project.startRename(/** @type {Entry} */ (lax.project.entryAt('/w/a.kup')));
    expect(await lax.project.commitName('A')).toEqual({
      renamed: { from: '/w/a.kup', to: '/w/A.kup' },
    });
  });

  it('is given once while it is being made, and left with cancel', async () => {
    const { project, fs } = projectOn(FILES);
    await project.list();
    project.startNew('script', '/w');
    const slow = gate();
    fs.exists.mockImplementationOnce(async () => {
      await slow.promise;
      return false;
    });
    const first = project.commitName('b');
    const second = project.commitName('c');
    slow.resolve();
    const done = await first;
    expect([done && 'made' in done ? done.made.path : null, await second]).toEqual([
      '/w/b.kup',
      null,
    ]);
    project.startNew('script', '/w');
    project.cancelNaming();
    expect(project.editing).toBeNull();
  });
});

describe("the project's files", () => {
  it('removes an entry, forgetting its scripts, closed folders and saves; a failure said', async () => {
    const { project, disk, fs, onproblem } = projectOn({ ...FILES, '/w/parts/inner/x.kup': '' });
    await project.list();
    await project.scripts.read('/w/parts/lid.kup');
    project.toggle('/w/parts/inner', false);
    expect(await project.remove(/** @type {Entry} */ (project.entryAt('/w/parts')))).toBe(true);
    expect([
      disk.has('/w/parts/lid.kup'),
      project.scripts.has('/w/parts/lid.kup'),
      project.collapsed.size,
    ]).toEqual([false, false, 0]);
    expect(paths(project.entries)).toEqual(['/w/a.kup']);
    fs.remove.mockRejectedValueOnce(new Error('locked'));
    expect(await project.remove(/** @type {Entry} */ (project.entryAt('/w/a.kup')))).toBe(false);
    expect(onproblem).toHaveBeenCalledWith("a.kup wasn't removed: locked");
  });

  it('adds files given to a folder, asking of a clash, the refused said, the folder shown', async () => {
    const { project, disk, onproblem } = projectOn(FILES);
    await project.list();
    project.toggle('/w/parts', false);
    const clash = vi.fn(async () => /** @type {const} */ ('rename'));
    const put = await project.addFiles(
      [new File(['new'], 'lid.kup'), new File([''], 'notes.txt'), new File(['{}'], 'sizes.json')],
      '/w/parts',
      clash,
    );
    expect(put).toEqual(['/w/parts/lid 2.kup', '/w/parts/sizes.json']);
    expect(clash).toHaveBeenCalledWith('lid.kup', 'lid 2.kup', 'parts');
    expect(onproblem).toHaveBeenCalledWith(
      'Not added, being no script or file a script reads: notes.txt',
    );
    expect([disk.get('/w/parts/lid 2.kup'), project.collapsed.size]).toEqual(['new', 0]);
    expect(paths(project.entries)).toContain('/w/parts/sizes.json');
  });

  it('names the root as the project to a clash in it', async () => {
    const { project } = projectOn(FILES);
    const clash = vi.fn(async () => /** @type {const} */ ('cancel'));
    expect(await project.addFiles([new File([''], 'a.kup')], '/w', clash)).toEqual([]);
    expect(clash).toHaveBeenCalledWith('a.kup', 'a 2.kup', 'w');
  });
});

describe('saving by itself', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('asks the host to save a script once it stays as edited for the time set, the last edit counting', async () => {
    const { project, onsave } = projectOn(FILES, { saveAfterMs: () => 100 });
    await project.scripts.read('/w/a.kup');
    project.edit('/w/a.kup', 'cube(2)\n');
    vi.advanceTimersByTime(60);
    project.edit('/w/a.kup', 'cube(3)\n');
    vi.advanceTimersByTime(60);
    expect(onsave).not.toHaveBeenCalled();
    vi.advanceTimersByTime(40);
    expect(onsave).toHaveBeenCalledExactlyOnceWith('/w/a.kup');
    expect(project.scripts.text('/w/a.kup')).toBe('cube(3)\n');
  });

  it('saves none by itself where the host says not, and none once saved by hand or disposed', async () => {
    const { project, onsave } = projectOn(FILES, { saveAfterMs: () => null });
    await project.scripts.read('/w/a.kup');
    project.edit('/w/a.kup', 'cube(2)\n');
    vi.advanceTimersByTime(10_000);
    expect(onsave).not.toHaveBeenCalled();
    const timed = projectOn(FILES, { saveAfterMs: () => 100 });
    await timed.project.scripts.read('/w/a.kup');
    timed.project.edit('/w/a.kup', 'cube(2)\n');
    timed.project.saving('/w/a.kup');
    timed.project.edit('/w/parts/lid.kup', 'x');
    timed.project.dispose();
    vi.advanceTimersByTime(1000);
    expect(timed.onsave).not.toHaveBeenCalled();
  });
});
