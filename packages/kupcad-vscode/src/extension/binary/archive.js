// One file out of a release's archive, with Node's zlib alone: a .tar.gz (ustar) or a .zip
// (stored or deflated). The archive was checked against the release's checksum before.

import { gunzipSync, inflateRawSync } from 'node:zlib';

/** A tar's records are this long, a header one of them. */
const TAR_BLOCK = 512;
const ZIP_END = 0x06054b50;
const ZIP_ENTRY = 0x02014b50;
const ZIP_LOCAL = 0x04034b50;
/** The end of a zip's central directory is this long, before its comment. */
const ZIP_END_BYTES = 22;
const ZIP_STORED = 0;
const ZIP_DEFLATED = 8;

/**
 * The bytes of the file named `name` at the top of the archive, or null when it has none.
 * @param {Uint8Array} archive
 * @param {'tar.gz' | 'zip'} format
 * @param {string} name
 * @returns {Uint8Array | null}
 */
export function extractFile(archive, format, name) {
  return format === 'zip' ? fromZip(archive, name) : fromTar(gunzipSync(archive), name);
}

/**
 * @param {Uint8Array} tar
 * @param {string} name
 */
function fromTar(tar, name) {
  const text = new TextDecoder();
  /** @param {number} at @param {number} length */
  const field = (at, length) => text.decode(tar.subarray(at, at + length)).replace(/\0.*$/s, '');
  for (let at = 0; at + TAR_BLOCK <= tar.length;) {
    const entry = field(at, 100);
    if (entry === '') return null; // the zero blocks that end it
    const prefix = field(at + 345, 155);
    const size = Number.parseInt(field(at + 124, 12).trim() || '0', 8);
    const type = field(at + 156, 1);
    const path = (prefix ? `${prefix}/${entry}` : entry).replace(/^\.\//, '');
    const data = at + TAR_BLOCK;
    if (path === name && (type === '' || type === '0'))
      return new Uint8Array(tar.subarray(data, data + size));
    at = data + Math.ceil(size / TAR_BLOCK) * TAR_BLOCK;
  }
  return null;
}

/**
 * @param {Uint8Array} zip
 * @param {string} name
 */
function fromZip(zip, name) {
  const view = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
  let end = zip.length - ZIP_END_BYTES;
  while (end >= 0 && view.getUint32(end, true) !== ZIP_END) end -= 1;
  if (end < 0) throw new Error('the archive is no zip: it has no central directory');
  const entries = view.getUint16(end + 10, true);
  let at = view.getUint32(end + 16, true);
  const text = new TextDecoder();
  for (let i = 0; i < entries; i++) {
    if (view.getUint32(at, true) !== ZIP_ENTRY) throw new Error("the zip's directory is broken");
    const method = view.getUint16(at + 10, true);
    const compressed = view.getUint32(at + 20, true);
    const nameLength = view.getUint16(at + 28, true);
    const extraLength = view.getUint16(at + 30, true);
    const commentLength = view.getUint16(at + 32, true);
    const local = view.getUint32(at + 42, true);
    if (text.decode(zip.subarray(at + 46, at + 46 + nameLength)) === name) {
      if (view.getUint32(local, true) !== ZIP_LOCAL) throw new Error("the zip's entry is broken");
      const data = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
      const bytes = zip.subarray(data, data + compressed);
      if (method === ZIP_STORED) return new Uint8Array(bytes);
      if (method === ZIP_DEFLATED) return new Uint8Array(inflateRawSync(bytes));
      throw new Error(`the zip's ${name} is compressed in a way this can't read (${method})`);
    }
    at += 46 + nameLength + extraLength + commentLength;
  }
  return null;
}
