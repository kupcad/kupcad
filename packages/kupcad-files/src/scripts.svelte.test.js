import { describe, expect, it, vi } from 'vitest';
import { Scripts } from './scripts.svelte.js';

/** A promise a test resolves when it wants (the app's ES2023 has no Promise.withResolvers). */
function gate() {
  /** @type {((value?: unknown) => void) | undefined} */
  let open;
  const promise = new Promise((done) => (open = done));
  return { promise, resolve: () => open?.() };
}

/** Scripts on a disk of `files`, which a test changes as another program would. */
function scriptsOn(/** @type {Record<string, string>} */ files) {
  const disk = new Map(Object.entries(files));
  const io = {
    read: vi.fn(async (/** @type {string} */ path) => {
      const text = disk.get(path);
      if (text === undefined) throw new Error(`no such file: ${path}`);
      return text;
    }),
    write: vi.fn(async (/** @type {string} */ path, /** @type {string} */ text) => {
      disk.set(path, text);
    }),
    exists: vi.fn(async (/** @type {string} */ path) => disk.has(path)),
  };
  return { scripts: new Scripts(io), disk, io };
}

describe('the scripts read', () => {
  it('are read once, unsaved once changed, and saved as they are', async () => {
    const { scripts, io, disk } = scriptsOn({ '/w/a.kup': 'cube(1)\n' });
    expect(await scripts.read('/w/a.kup')).toBe('cube(1)\n');
    expect(await scripts.read('/w/a.kup')).toBe('cube(1)\n');
    expect(io.read).toHaveBeenCalledOnce();
    scripts.edit('/w/a.kup', 'cube(2)\n');
    expect([...scripts.unsaved]).toEqual(['/w/a.kup']);
    // Back to what the disk has: nothing to save
    scripts.edit('/w/a.kup', 'cube(1)\n');
    expect(scripts.unsaved.size).toBe(0);
    scripts.edit('/w/a.kup', 'cube(3)\n');
    expect(await scripts.save('/w/a.kup')).toBe('saved');
    expect(disk.get('/w/a.kup')).toBe('cube(3)\n');
    expect(scripts.unsaved.size).toBe(0);
  });

  it('keep what is typed while a save writes, unsaved', async () => {
    const { scripts, io } = scriptsOn({ '/w/a.kup': 'a' });
    await scripts.read('/w/a.kup');
    scripts.edit('/w/a.kup', 'ab');
    const written = gate();
    io.write.mockImplementationOnce(() => written.promise);
    const saving = scripts.save('/w/a.kup');
    await vi.waitFor(() => expect(io.write).toHaveBeenCalled());
    scripts.edit('/w/a.kup', 'abc');
    written.resolve();
    await saving;
    expect(scripts.text('/w/a.kup')).toBe('abc');
    expect([...scripts.unsaved]).toEqual(['/w/a.kup']);
  });
});

describe('a script the disk changed under', () => {
  it('takes the disk’s text where the person changed nothing', async () => {
    const { scripts, disk } = scriptsOn({ '/w/a.kup': 'cube(1)\n' });
    await scripts.read('/w/a.kup');
    disk.set('/w/a.kup', 'cube(9)\n');
    expect(await scripts.check()).toEqual([]);
    expect(scripts.text('/w/a.kup')).toBe('cube(9)\n');
    expect(scripts.unsaved.size).toBe(0);
    expect(scripts.conflicts.size).toBe(0);
  });

  it('keeps the person’s changes, the disk’s held for them to choose', async () => {
    const { scripts, disk } = scriptsOn({ '/w/a.kup': 'cube(1)\n', '/w/b.kup': 'b' });
    await scripts.read('/w/a.kup');
    await scripts.read('/w/b.kup');
    scripts.edit('/w/a.kup', 'mine\n');
    scripts.edit('/w/b.kup', 'theirs');
    disk.set('/w/a.kup', 'theirs\n');
    disk.set('/w/b.kup', 'theirs');
    await scripts.check();
    expect(scripts.text('/w/a.kup')).toBe('mine\n');
    expect(scripts.conflicts.get('/w/a.kup')).toBe('theirs\n');
    // The same change both ways is none to choose between
    expect(scripts.conflicts.has('/w/b.kup')).toBe(false);
    expect(scripts.unsaved.has('/w/b.kup')).toBe(false);

    scripts.resolve('/w/a.kup', 'disk');
    expect(scripts.text('/w/a.kup')).toBe('theirs\n');
    expect(scripts.unsaved.size).toBe(0);
    expect(scripts.conflicts.size).toBe(0);
  });

  it("keeps the person's own when they choose it, and the next save writes it over the disk's", async () => {
    const { scripts, disk } = scriptsOn({ '/w/a.kup': 'cube(1)\n' });
    await scripts.read('/w/a.kup');
    scripts.edit('/w/a.kup', 'mine\n');
    disk.set('/w/a.kup', 'theirs\n');
    await scripts.check();
    scripts.resolve('/w/a.kup', 'mine');
    expect(scripts.conflicts.size).toBe(0);
    expect(scripts.unsaved.has('/w/a.kup')).toBe(true);
    expect(await scripts.save('/w/a.kup')).toBe('saved');
    expect(disk.get('/w/a.kup')).toBe('mine\n');
  });

  it("isn't written over by a save the watcher was too late for, unless told to", async () => {
    const { scripts, disk } = scriptsOn({ '/w/a.kup': 'cube(1)\n' });
    await scripts.read('/w/a.kup');
    scripts.edit('/w/a.kup', 'mine\n');
    disk.set('/w/a.kup', 'theirs\n');
    expect(await scripts.save('/w/a.kup')).toBe('changed');
    expect(disk.get('/w/a.kup')).toBe('theirs\n');
    expect(scripts.conflicts.get('/w/a.kup')).toBe('theirs\n');
    expect(await scripts.save('/w/a.kup', { overwrite: true })).toBe('saved');
    expect(disk.get('/w/a.kup')).toBe('mine\n');
    expect(scripts.conflicts.size).toBe(0);
  });

  it("doesn't take its own save for another's change, typing going on meanwhile", async () => {
    const { scripts, io, disk } = scriptsOn({ '/w/a.kup': 'a' });
    await scripts.read('/w/a.kup');
    scripts.edit('/w/a.kup', 'ab');
    const done = gate();
    // The disk has the save's text before the save is done
    io.write.mockImplementationOnce(async (path, text) => {
      disk.set(path, text);
      await done.promise;
    });
    const saving = scripts.save('/w/a.kup');
    await vi.waitFor(() => expect(disk.get('/w/a.kup')).toBe('ab'));
    scripts.edit('/w/a.kup', 'abc');
    await scripts.check();
    expect(scripts.conflicts.size).toBe(0);
    done.resolve();
    await saving;
    await scripts.check();
    expect(scripts.conflicts.size).toBe(0);
    expect(scripts.text('/w/a.kup')).toBe('abc');
    expect([...scripts.unsaved]).toEqual(['/w/a.kup']);
  });
});

describe('a script gone from the disk', () => {
  it('is dropped where the person changed nothing', async () => {
    const { scripts, disk } = scriptsOn({ '/w/a.kup': 'a' });
    await scripts.read('/w/a.kup');
    disk.delete('/w/a.kup');
    expect(await scripts.check()).toEqual(['/w/a.kup']);
    expect(scripts.has('/w/a.kup')).toBe(false);
  });

  it('is kept, unsaved, where they did: discarded, or saved back', async () => {
    const { scripts, disk } = scriptsOn({ '/w/a.kup': 'a', '/w/b.kup': 'b' });
    for (const path of ['/w/a.kup', '/w/b.kup']) {
      await scripts.read(path);
      scripts.edit(path, 'changed');
      disk.delete(path);
    }
    expect(await scripts.check()).toEqual([]);
    expect(scripts.conflicts.get('/w/a.kup')).toBeNull();
    scripts.resolve('/w/a.kup', 'disk');
    expect(scripts.has('/w/a.kup')).toBe(false);
    scripts.resolve('/w/b.kup', 'mine');
    expect(await scripts.save('/w/b.kup')).toBe('saved');
    expect(disk.get('/w/b.kup')).toBe('changed');
  });

  it("is left as it is where the disk can't be read for another reason", async () => {
    const { scripts, io } = scriptsOn({ '/w/a.kup': 'a' });
    await scripts.read('/w/a.kup');
    io.read.mockRejectedValueOnce(new Error('denied'));
    expect(await scripts.check()).toEqual([]);
    expect(scripts.text('/w/a.kup')).toBe('a');
    expect(scripts.conflicts.size).toBe(0);
  });
});

it('moves or forgets what it holds of the scripts under a folder renamed or removed', async () => {
  const { scripts, disk } = scriptsOn({ '/w/p/a.kup': 'a', '/w/p/b.kup': 'b', '/w/pq.kup': 'c' });
  for (const path of disk.keys()) await scripts.read(path);
  scripts.edit('/w/p/a.kup', 'mine');
  scripts.keep('/w/p/a.kup', { doc: 'a' });
  disk.set('/w/p/a.kup', 'theirs');
  await scripts.check();
  scripts.rename('/w/p', '/w/parts');
  expect(scripts.text('/w/parts/a.kup')).toBe('mine');
  expect(scripts.conflicts.get('/w/parts/a.kup')).toBe('theirs');
  expect(scripts.snapshot('/w/parts/a.kup')).toEqual({ doc: 'a' });
  expect(scripts.has('/w/p/b.kup')).toBe(false);
  // A sibling whose name starts the same isn't in it
  expect(scripts.has('/w/pq.kup')).toBe(true);
  scripts.drop('/w/parts');
  expect([scripts.has('/w/parts/a.kup'), scripts.has('/w/parts/b.kup')]).toEqual([false, false]);
  expect(scripts.unsaved.size).toBe(0);
  expect(scripts.snapshot('/w/parts/a.kup')).toBeUndefined();
});

describe('a save', () => {
  it('writes nothing where the disk has the text already', async () => {
    const { scripts, io } = scriptsOn({ '/w/a.kup': 'cube(1)\n' });
    await scripts.read('/w/a.kup');
    expect(await scripts.save('/w/a.kup')).toBe('saved');
    expect(io.write).not.toHaveBeenCalled();
  });

  it("doesn't bring back a script dropped or renamed while it was written", async () => {
    const { scripts, io } = scriptsOn({ '/w/a.kup': 'cube(1)\n' });
    const writing = gate();
    io.write.mockImplementationOnce(() => writing.promise);
    await scripts.read('/w/a.kup');
    scripts.edit('/w/a.kup', 'cube(2)\n');
    const saving = scripts.save('/w/a.kup');
    scripts.rename('/w/a.kup', '/w/b.kup');
    writing.resolve();
    expect(await saving).toBe('saved');
    expect([scripts.has('/w/a.kup'), scripts.has('/w/b.kup')]).toEqual([false, true]);
  });
});
