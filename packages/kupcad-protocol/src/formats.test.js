import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import { EXPORT_FORMATS, exportFormatsFor } from './index.js';

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

/**
 * The formats offered a model of `kind`.
 * @param {import('./types.js').Kind} kind
 */
const formats = (kind) => exportFormatsFor(kind).map((f) => f.format);

it("offers a 2D model its drawings alone, a 3D one or none every format, as the core's dimensions say", () => {
  expect(formats('2d')).toEqual(['svg', 'dxf']);
  expect(formats('3d')).toEqual(EXPORT_FORMATS.map((f) => f.format));
  expect(formats('none')).toEqual(EXPORT_FORMATS.map((f) => f.format));
  // core/src/exporters/format.zig's `dimension`: `.svg, .dxf => .@"2d"`
  const source = readFileSync(
    new URL('../../../core/src/exporters/format.zig', import.meta.url),
    'utf8',
  );
  const drawn = /\s([.\w@", ]+) => \.@"2d"/.exec(source)?.[1] ?? '';
  expect(drawn.split(',').map((name) => name.trim().replace(/^\./, ''))).toEqual(formats('2d'));
});
