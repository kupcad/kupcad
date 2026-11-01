// The formats the core writes a model in (`kupcad build`, @kupcad/wasm's `build`), as a host
// offers them: each its name, what it is for and the file extensions it is written under, in the
// order to offer them, and those a model of each kind can be written in. The one table (the
// desktop app kept its own extensions, and the native side its own list, which a test of its
// holds to this one).

import { extensionOf } from './names.js';

/** @import { ExportFormat, Kind } from './types.js' */

/**
 * @typedef {object} ExportChoice
 * @property {ExportFormat} format the file's extension too
 * @property {string} label
 * @property {string} detail what it is for
 * @property {readonly string[]} extensions the file extensions it is written under, the first
 *   the one to name a file by (core/src/exporters/format.zig's)
 * @property {boolean} drawing a drawing on XY, which any model can be; else a 3D format, which
 *   the core refuses a 2D model (a Sketch, a Path) in
 */

/** @type {readonly ExportChoice[]} */
export const EXPORT_FORMATS = [
  {
    format: 'stl',
    label: 'STL',
    detail: 'A mesh, for a slicer or any 3D tool',
    extensions: ['stl'],
    drawing: false,
  },
  {
    format: '3mf',
    label: '3MF',
    detail: 'A mesh with its parts, copies and colours, for a slicer',
    extensions: ['3mf'],
    drawing: false,
  },
  {
    format: 'step',
    label: 'STEP',
    detail: 'Exact geometry, for CAD (the B-Rep engine)',
    extensions: ['step', 'stp'],
    drawing: false,
  },
  {
    format: 'glb',
    label: 'GLB',
    detail: 'Binary glTF, with its parts and colours, for the web',
    extensions: ['glb'],
    drawing: false,
  },
  { format: 'gltf', label: 'glTF', detail: 'glTF as JSON', extensions: ['gltf'], drawing: false },
  {
    format: 'obj',
    label: 'OBJ',
    detail: 'Wavefront OBJ, a part an object',
    extensions: ['obj'],
    drawing: false,
  },
  {
    format: 'svg',
    label: 'SVG',
    detail: 'A drawing on XY, for a laser cutter',
    extensions: ['svg'],
    drawing: true,
  },
  {
    format: 'dxf',
    label: 'DXF',
    detail: 'The drawing as DXF, for CAD and CNC',
    extensions: ['dxf'],
    drawing: true,
  },
];

/**
 * The format a file named `path` is written in, by its extension in any case; null for one
 * kupcad doesn't write (then `-f` says, or the build refuses the name).
 * @param {string} path
 * @returns {ExportFormat | null}
 */
export function formatOf(path) {
  const extension = extensionOf(path);
  return (
    EXPORT_FORMATS.find((choice) => choice.extensions.includes(extension ?? ''))?.format ?? null
  );
}

/**
 * The formats a model of `kind` can be written in: a 2D model's drawings alone, any for a 3D
 * one, and any while there is none to go by (a run that failed says why itself).
 * @param {Kind} kind
 * @returns {readonly ExportChoice[]}
 */
export const exportFormatsFor = (kind) =>
  kind === '2d' ? EXPORT_FORMATS.filter((choice) => choice.drawing) : EXPORT_FORMATS;

/**
 * Whether `value` is a format the core writes.
 * @param {unknown} value
 * @returns {value is ExportFormat}
 */
export const isExportFormat = (value) => EXPORT_FORMATS.some((choice) => choice.format === value);
