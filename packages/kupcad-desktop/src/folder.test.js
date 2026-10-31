import { describe, expect, it, vi } from 'vitest';
import { changesTree, fileUri, pickFolder, WATCH_DELAY_MS, watchFolder } from './folder.js';

/** @import { WatchEvent } from '@tauri-apps/plugin-fs' */

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

it('watches everything under the folder, telling of a file written, and whether the tree changed', async () => {
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
  // Read, or only in a folder the tree leaves out: nothing of the user's
  report(event({ access: { kind: 'open', mode: 'read' } }, ['/w/b.kup']));
  report(event({ modify: { kind: 'data', mode: 'content' } }, ['/w/.git/index']));
  expect(onchange).not.toHaveBeenCalled();
  // Written in place, as another editor saves: a file to read again, the tree as it was
  report(event({ modify: { kind: 'data', mode: 'content' } }, ['/w/b.kup']));
  expect(onchange).toHaveBeenLastCalledWith({ tree: false });
  report(event({ create: { kind: 'file' } }, ['/w/c.kup']));
  expect(onchange).toHaveBeenLastCalledWith({ tree: true });
  unwatch();
  expect(stop).toHaveBeenCalledOnce();
});

it('gives a file the URI the server knows it by, each segment percent-encoded', () => {
  expect(fileUri('/w/my part #1.kup')).toBe('file:///w/my%20part%20%231.kup');
  expect(fileUri('/w/ünit.kup')).toBe('file:///w/%C3%BCnit.kup');
  expect(fileUri('C:\\w\\a.kup')).toBe('file:///C%3A/w/a.kup');
});

it('picks a folder with what is under it, or none', async () => {
  const open = vi.fn().mockResolvedValueOnce('/w').mockResolvedValueOnce(null);
  expect(await pickFolder({ open })).toBe('/w');
  expect(open).toHaveBeenCalledWith(expect.objectContaining({ directory: true, recursive: true }));
  expect(await pickFolder({ open })).toBeNull();
});
