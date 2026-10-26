// The formats the core writes a model in (`kupcad build`, @kupcad/wasm's `build`), as a host
// offers them: each its name and what it is for, in the order to offer them, and those a model of
// each kind can be written in.

/** @import { ExportFormat, Kind } from './types.js' */

/**
 * @typedef {object} ExportChoice
 * @property {ExportFormat} format the file's extension too
 * @property {string} label
 * @property {string} detail what it is for
 * @property {boolean} drawing a drawing on XY, which any model can be; else a 3D format, which
 *   the core refuses a 2D model (a Sketch, a Path) in
 */

/** @type {readonly ExportChoice[]} */
export const EXPORT_FORMATS = [
  { format: 'stl', label: 'STL', detail: 'A mesh, for a slicer or any 3D tool', drawing: false },
  {
    format: '3mf',
    label: '3MF',
    detail: 'A mesh with its parts, copies and colours, for a slicer',
    drawing: false,
  },
  {
    format: 'step',
    label: 'STEP',
    detail: 'Exact geometry, for CAD (the B-Rep engine)',
    drawing: false,
  },
  {
    format: 'glb',
    label: 'GLB',
    detail: 'Binary glTF, with its parts and colours, for the web',
    drawing: false,
  },
  { format: 'gltf', label: 'glTF', detail: 'glTF as JSON', drawing: false },
  { format: 'obj', label: 'OBJ', detail: 'Wavefront OBJ, a part an object', drawing: false },
  { format: 'svg', label: 'SVG', detail: 'A drawing on XY, for a laser cutter', drawing: true },
  { format: 'dxf', label: 'DXF', detail: 'The drawing as DXF, for CAD and CNC', drawing: true },
];

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
