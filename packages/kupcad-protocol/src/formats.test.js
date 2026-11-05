import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import { EXPORT_FORMATS, exportFormatFor, exportFormatsFor, formatOf } from './index.js';

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

it('reads an export file name as the format it is written in, by its extension in any case', () => {
  // The desktop app read it with a table of extensions of its own
  expect(
    ['a.STL', 'a.stp', 'a.step', 'a.3mf', 'a.txt', 'stl', '/w.3mf/part'].map(formatOf),
  ).toEqual(['stl', 'step', 'step', '3mf', null, null, null]);
  // Each format names files by its first extension, which is its own name
  for (const choice of EXPORT_FORMATS) expect(choice.extensions[0]).toBe(choice.format);
});

it('writes an export in the format its name says, else in the one the dialog was for', () => {
  expect(exportFormatFor('/out/part.stp', 'step')).toBe('step');
  // A name of another format, typed in the STEP dialog
  expect(exportFormatFor('/out/part.stl', 'step')).toBe('stl');
  expect(exportFormatFor('/out/part', '3mf')).toBe('3mf');
  expect(exportFormatFor('/out/part.model', 'glb')).toBe('glb');
});
