// The formats the core writes a model in (`kupcad build`, @kupcad/wasm's `build`), as a host
// offers them: each its name and what it is for, in the order to offer them.

/** @import { ExportFormat } from './types.js' */

/**
 * @typedef {object} ExportChoice
 * @property {ExportFormat} format the file's extension too
 * @property {string} label
 * @property {string} detail what it is for
 */

/** @type {readonly ExportChoice[]} */
export const EXPORT_FORMATS = [
  { format: 'stl', label: 'STL', detail: 'A mesh, for a slicer or any 3D tool' },
  {
    format: '3mf',
    label: '3MF',
    detail: 'A mesh with its parts, copies and colours, for a slicer',
  },
  { format: 'step', label: 'STEP', detail: 'Exact geometry, for CAD (the B-Rep engine)' },
  { format: 'glb', label: 'GLB', detail: 'Binary glTF, with its parts and colours, for the web' },
  { format: 'gltf', label: 'glTF', detail: 'glTF as JSON' },
  { format: 'obj', label: 'OBJ', detail: 'Wavefront OBJ, a part an object' },
  { format: 'svg', label: 'SVG', detail: 'A drawing on XY, for a laser cutter' },
  { format: 'dxf', label: 'DXF', detail: 'The drawing as DXF, for CAD and CNC' },
];
