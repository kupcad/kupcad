import { expect, it } from 'vitest';
import { toBase64 } from './base64.js';

it('writes bytes as base64, past the chunk String.fromCharCode takes at once', () => {
  expect(toBase64(new TextEncoder().encode('PNG'))).toBe(btoa('PNG'));
  const many = new Uint8Array(100_000).map((_, i) => i % 256);
  const back = Uint8Array.from(atob(toBase64(many)), (c) => c.charCodeAt(0));
  expect(back).toEqual(many);
});
