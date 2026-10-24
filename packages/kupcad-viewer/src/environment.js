// What a model stands on, on the XY plane at z = 0: a grid sized to the model, a build plate,
// or nothing.

import {
  BufferGeometry,
  Float32BufferAttribute,
  Group,
  LineBasicMaterial,
  LineSegments,
  Mesh,
  MeshBasicMaterial,
  PlaneGeometry,
} from 'three';

/** @import { Box3 } from 'three' */
/** @import { Environment, Plate, Theme } from './types.js' */

/** A grid has this many cells along its side. */
const GRID_CELLS = 20;
/** A plate's grid has a line every this many millimetres. */
const PLATE_STEP_MM = 10;
/** The plate's surface sits this far below its lines, so they aren't lost in it. */
const PLATE_BELOW_MM = 0.01;
/** A grid's side, with no model to size it to. */
const DEFAULT_GRID_MM = 100;

/**
 * What `kind` stands a model of `box` on, in the theme's colours.
 * @param {Environment} kind
 * @param {Box3} box the model's bounds, empty with no model
 * @param {Plate} plate
 * @param {Theme} theme
 * @returns {Group}
 */
export function environmentOf(kind, box, plate, theme) {
  const group = new Group();
  if (kind === 'grid') {
    const side = gridSide(box);
    group.add(lines(side, side, side / GRID_CELLS, theme.grid));
  } else if (kind === 'plate') {
    const surface = new Mesh(
      new PlaneGeometry(plate.width, plate.depth),
      new MeshBasicMaterial({ color: theme.plate }),
    );
    surface.position.z = -PLATE_BELOW_MM;
    group.add(surface, lines(plate.width, plate.depth, PLATE_STEP_MM, theme.grid));
  }
  return group;
}

/**
 * A grid's side for a model of `box`: a round length (1, 2 or 5 times a power of ten, in mm)
 * past twice its extent across XY and from the origin.
 * @param {Box3} box
 * @returns {number}
 */
export function gridSide(box) {
  if (box.isEmpty()) return DEFAULT_GRID_MM;
  const reach = Math.max(
    Math.abs(box.min.x),
    Math.abs(box.max.x),
    Math.abs(box.min.y),
    Math.abs(box.max.y),
  );
  const wanted = Math.max(reach * 2, 1);
  const power = 10 ** Math.floor(Math.log10(wanted));
  const step = [1, 2, 5, 10].find((factor) => factor * power >= wanted) ?? 10;
  return step * power;
}

/**
 * Lines every `step` from the origin across a `width` × `depth` rectangle centred on it, and
 * along its edges. They ran from one edge, so a plate whose side isn't a whole number of steps
 * had none through the origin and one past its far edge.
 * @param {number} width
 * @param {number} depth
 * @param {number} step
 * @param {string} color
 * @returns {LineSegments}
 */
function lines(width, depth, step, color) {
  /** @type {number[]} */
  const positions = [];
  const halfW = width / 2;
  const halfD = depth / 2;
  for (const x of stops(halfW, step)) positions.push(x, -halfD, 0, x, halfD, 0);
  for (const y of stops(halfD, step)) positions.push(-halfW, y, 0, halfW, y, 0);
  const geometry = new BufferGeometry().setAttribute(
    'position',
    new Float32BufferAttribute(positions, 3),
  );
  return new LineSegments(geometry, new LineBasicMaterial({ color }));
}

/**
 * Where lines across ±`half` go: every whole `step` from 0 inside it (each a multiple, not a
 * sum, so they don't drift), and ±`half`.
 * @param {number} half
 * @param {number} step
 * @returns {number[]}
 */
export function stops(half, step) {
  // A multiple this near an edge is the edge
  const near = step * 1e-6;
  /** @type {number[]} */
  const inside = [];
  for (let i = Math.ceil(-half / step); i * step <= half; i++) {
    const at = i * step;
    if (Math.abs(Math.abs(at) - half) > near) inside.push(at);
  }
  return [-half, ...inside, half];
}
