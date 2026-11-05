import { expect, it } from 'vitest';
import { pngBase64, pngBytes } from './screenshot.js';

it("carries a screenshot's bytes as base64 and back, past the chunk String.fromCharCode takes", () => {
  expect(pngBase64(new TextEncoder().encode('PNG'))).toBe(btoa('PNG'));
  expect([...pngBytes(btoa('PNG'))]).toEqual([80, 78, 71]);
  const many = new Uint8Array(100_000).map((_, i) => i % 256);
  expect(pngBytes(pngBase64(many))).toEqual(many);
});
