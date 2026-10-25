import { expect, it } from 'vitest';
import { EXPORT_FORMATS } from './index.js';

it('offers each format the core writes, once', () => {
  expect(EXPORT_FORMATS.map((f) => f.format).toSorted()).toEqual([
    '3mf',
    'dxf',
    'glb',
    'gltf',
    'obj',
    'step',
    'stl',
    'svg',
  ]);
});
