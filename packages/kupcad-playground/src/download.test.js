import { afterEach, expect, it, vi } from 'vitest';
import { download } from './download.js';

afterEach(() => vi.restoreAllMocks());

it('saves bytes, or a blob, as the file named, and lets go of its URL', async () => {
  /** @type {Blob[]} */
  const blobs = [];
  vi.spyOn(URL, 'createObjectURL').mockImplementation((blob) => {
    blobs.push(/** @type {Blob} */ (blob));
    return `blob:${blobs.length}`;
  });
  const revoke = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
  /** @type {{ href: string, download: string }[]} */
  const clicked = [];
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(
    /** @this {HTMLAnchorElement} */ function () {
      clicked.push({ href: this.href, download: this.download });
    },
  );
  download(new Uint8Array([1, 2, 3]), 'bracket.stl');
  download(new Blob(['png']), 'bracket.png');
  expect(clicked).toEqual([
    { href: 'blob:1', download: 'bracket.stl' },
    { href: 'blob:2', download: 'bracket.png' },
  ]);
  expect(blobs[0].size).toBe(3);
  // Once the browser has taken them
  expect(revoke).not.toHaveBeenCalled();
  await new Promise((resolve) => setTimeout(resolve));
  expect(revoke).toHaveBeenCalledTimes(2);
});
