// Node's reader of a `file:` URL, for a module loaded from the disk (#read-file).

import { readFile as readFromDisk } from 'node:fs/promises';

/**
 * @param {URL} url
 * @returns {Promise<Uint8Array<ArrayBuffer>>}
 */
export async function readFile(url) {
  return readFromDisk(url);
}
