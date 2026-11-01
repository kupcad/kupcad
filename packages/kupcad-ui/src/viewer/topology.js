// A geometry's triangles as a surface: which meet which across an edge, by their corners' points
// (a mesh's faces may each have corners of their own), and the way each faces. Found once per
// geometry and kept beside it: the model's feature edges are drawn from it (model.js), where two
// triangles turn by more than EDGE_ANGLE_DEG, and the faces they bound are found in it (faces.js),
// so an edge and a face's border are one.

import { BufferGeometry, Float32BufferAttribute, Vector3 } from 'three';

/** Where a solid's faces meet at more than this many degrees, an edge is drawn: its features. */
export const EDGE_ANGLE_DEG = 20;
const EDGE_COS = Math.cos((EDGE_ANGLE_DEG * Math.PI) / 180);
/** Two corners nearer than this, of the geometry's size, are one point: its triangles meet there. */
const SAME_POINT = 1e-6;
/** Slots in a hash table per key it is given, at least: it stays at most half full. */
const TABLE_ROOM = 2;
/** Odd numbers that spread a key's parts over a hash table's slots. */
const SPREAD = [0x9e3779b1, 0x85ebca77, 0xc2b2ae3d];

/**
 * A geometry's triangles and which meet which across an edge. A triangle's sides are numbered
 * `triangle * 3 + corner`, each from its corner to the next.
 * @typedef {object} Topology
 * @property {Float32Array} normals a unit normal per triangle, 3 numbers each
 * @property {Uint8Array} degenerate 1 for a triangle two of whose corners are one point
 * @property {Int32Array} edgeOf the edge each side lies on, by its ends' points
 * @property {Int32Array} start where each edge's sides begin in `sides` (one more, the end)
 * @property {Int32Array} sides the sides on each edge, edge by edge
 */

/** @type {WeakMap<BufferGeometry, Topology>} */
const topologies = new WeakMap();

/**
 * The topology of `geometry`, found the first time it is asked for.
 * @param {BufferGeometry} geometry
 * @returns {Topology}
 */
export function topologyOf(geometry) {
  let topology = topologies.get(geometry);
  if (!topology) {
    topology = build(geometry);
    topologies.set(geometry, topology);
  }
  return topology;
}

/**
 * Whether triangles `t` and `u` turn by more than EDGE_ANGLE_DEG where they meet: an edge is
 * drawn between them, and they are of two faces.
 * @param {Topology} topology
 * @param {number} t
 * @param {number} u
 */
export function turns({ normals }, t, u) {
  const cos =
    normals[t * 3] * normals[u * 3] +
    normals[t * 3 + 1] * normals[u * 3 + 1] +
    normals[t * 3 + 2] * normals[u * 3 + 2];
  return cos <= EDGE_COS;
}

/**
 * The feature edges of `geometry` as line segments: each edge where its two triangles turn by
 * more than EDGE_ANGLE_DEG, or with one triangle (the border of an open mesh) or more than two;
 * a degenerate triangle has none. As three.js's EdgesGeometry draws them, which made a string for
 * each corner: 1.2 s at 500k triangles.
 * @param {BufferGeometry} geometry
 * @returns {BufferGeometry}
 */
export function featureEdgesOf(geometry) {
  const topology = topologyOf(geometry);
  const { degenerate, start, sides } = topology;
  const position = geometry.getAttribute('position');
  const index = geometry.getIndex();
  /** @param {number} side */
  const vertex = (side) => (index ? index.getX(side) : side);
  const drawn = [];
  for (let edge = 0; edge + 1 < start.length; edge++) {
    let first = -1;
    let count = 0;
    let turned = false;
    for (let on = start[edge]; on < start[edge + 1]; on++) {
      const t = Math.floor(sides[on] / 3);
      if (degenerate[t]) continue;
      if (count === 0) first = sides[on];
      else turned = turns(topology, Math.floor(first / 3), t);
      count++;
    }
    if (count === 1 || count > 2 || turned) drawn.push(first);
  }
  const positions = new Float32Array(drawn.length * 6);
  drawn.forEach((side, i) => {
    for (const [end, v] of [vertex(side), vertex(nextSide(side))].entries()) {
      positions[i * 6 + end * 3] = position.getX(v);
      positions[i * 6 + end * 3 + 1] = position.getY(v);
      positions[i * 6 + end * 3 + 2] = position.getZ(v);
    }
  });
  return new BufferGeometry().setAttribute('position', new Float32BufferAttribute(positions, 3));
}

/**
 * The side after `side` around its triangle.
 * @param {number} side
 */
function nextSide(side) {
  return side % 3 === 2 ? side - 2 : side + 1;
}

/**
 * The triangles of `geometry`, their normals, and which meet which: across an edge whose two
 * ends each triangle has (by their points, as a mesh's faces each have corners of their own).
 * Typed arrays throughout: a mesh of a million triangles took seconds, a string and an array
 * made for each.
 * @param {BufferGeometry} geometry
 * @returns {Topology}
 */
function build(geometry) {
  const position = geometry.getAttribute('position');
  const index = geometry.getIndex();
  const count = (index ? index.count : position.count) / 3;
  const sideCount = count * 3;
  /** @param {number} side */
  const vertex = (side) => (index ? index.getX(side) : side);
  const pointOf = pointsOf(geometry);
  const normals = new Float32Array(count * 3);
  const a = new Vector3();
  const b = new Vector3();
  const c = new Vector3();
  for (let t = 0; t < count; t++) {
    a.fromBufferAttribute(position, vertex(t * 3));
    b.fromBufferAttribute(position, vertex(t * 3 + 1));
    c.fromBufferAttribute(position, vertex(t * 3 + 2));
    c.sub(b)
      .cross(a.sub(b))
      .normalize()
      .toArray(normals, t * 3);
  }
  // Each side's ends, the lower point first, so a side and its twin are one key
  const low = new Int32Array(sideCount);
  const high = new Int32Array(sideCount);
  const degenerate = new Uint8Array(count);
  for (let side = 0; side < sideCount; side++) {
    const p = pointOf[vertex(side)];
    const q = pointOf[vertex(nextSide(side))];
    low[side] = Math.min(p, q);
    high[side] = Math.max(p, q);
    if (p === q) degenerate[Math.floor(side / 3)] = 1;
  }
  const edges = intern(
    sideCount,
    (side) => Math.imul(low[side], SPREAD[0]) ^ Math.imul(high[side], SPREAD[1]),
    (side, other) => low[side] === low[other] && high[side] === high[other],
  );
  const start = new Int32Array(edges.count + 1);
  for (let side = 0; side < sideCount; side++) start[edges.ids[side] + 1]++;
  for (let edge = 0; edge < edges.count; edge++) start[edge + 1] += start[edge];
  const sides = new Int32Array(sideCount);
  const filled = start.slice(0, edges.count);
  for (let side = 0; side < sideCount; side++) sides[filled[edges.ids[side]]++] = side;
  return { normals, degenerate, edgeOf: edges.ids, start, sides };
}

/**
 * The point each vertex of `geometry` is at: vertices nearer than SAME_POINT of its size are at
 * one.
 * @param {BufferGeometry} geometry
 */
function pointsOf(geometry) {
  const position = geometry.getAttribute('position');
  geometry.computeBoundingBox();
  const size = geometry.boundingBox?.getSize(new Vector3()).length() || 1;
  const step = size * SAME_POINT;
  const grid = new Float64Array(position.count * 3);
  for (let v = 0; v < position.count; v++) {
    grid[v * 3] = Math.round(position.getX(v) / step);
    grid[v * 3 + 1] = Math.round(position.getY(v) / step);
    grid[v * 3 + 2] = Math.round(position.getZ(v) / step);
  }
  return intern(
    position.count,
    (v) =>
      Math.imul(grid[v * 3], SPREAD[0]) ^
      Math.imul(grid[v * 3 + 1], SPREAD[1]) ^
      Math.imul(grid[v * 3 + 2], SPREAD[2]),
    (v, w) =>
      grid[v * 3] === grid[w * 3] &&
      grid[v * 3 + 1] === grid[w * 3 + 1] &&
      grid[v * 3 + 2] === grid[w * 3 + 2],
  ).ids;
}

/**
 * Ids for `count` keys, the same for equal keys and counted from 0 in the order they first
 * come: by an open-addressing table of the first key of each id.
 * @param {number} count
 * @param {(key: number) => number} hash
 * @param {(key: number, other: number) => boolean} same
 * @returns {{ ids: Int32Array, count: number }}
 */
function intern(count, hash, same) {
  let size = 1;
  while (size < count * TABLE_ROOM) size *= 2;
  const mask = size - 1;
  const firsts = new Int32Array(size).fill(-1);
  const ids = new Int32Array(count);
  let distinct = 0;
  for (let key = 0; key < count; key++) {
    for (let slot = hash(key) & mask; ; slot = (slot + 1) & mask) {
      const first = firsts[slot];
      if (first < 0) {
        firsts[slot] = key;
        ids[key] = distinct++;
        break;
      }
      if (same(key, first)) {
        ids[key] = ids[first];
        break;
      }
    }
  }
  return { ids, count: distinct };
}
