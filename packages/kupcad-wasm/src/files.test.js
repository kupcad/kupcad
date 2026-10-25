import { describe, expect, it } from 'vitest';
import { packFiles } from './files.js';

describe('packFiles', () => {
  it('writes each path and content after its length, little-endian, one file after another', () => {
    const packed = packFiles({ 'a.kup': 'x = 1', 'd/é.bin': new Uint8Array([7, 8]) });
    const view = new DataView(packed.buffer);
    const decoder = new TextDecoder();
    expect(view.getUint32(0, true)).toBe(5);
    expect(decoder.decode(packed.subarray(4, 9))).toBe('a.kup');
    expect(view.getUint32(9, true)).toBe(5);
    expect(decoder.decode(packed.subarray(13, 18))).toBe('x = 1');
    // A path's length is its bytes' (é is two), not its characters'
    expect(view.getUint32(18, true)).toBe(8);
    expect(decoder.decode(packed.subarray(22, 30))).toBe('d/é.bin');
    expect(view.getUint32(30, true)).toBe(2);
    expect([...packed.subarray(34)]).toEqual([7, 8]);
    expect(packed.byteLength).toBe(36);
  });

  it('packs no files as no bytes, and an empty content as its length alone', () => {
    expect(packFiles({}).byteLength).toBe(0);
    const packed = packFiles({ 'empty.txt': '' });
    expect(packed.byteLength).toBe(4 + 9 + 4);
    expect(new DataView(packed.buffer).getUint32(13, true)).toBe(0);
  });
});
