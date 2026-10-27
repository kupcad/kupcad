// A mesh's faces, as its feature edges bound them: the triangles joined across their edges where
// they meet at less than EDGE_ANGLE_DEG (model.js draws an edge where they meet at more). A face
// is flat when its triangles all face one way, curved otherwise (a cylinder's side); its area is
// in the scene's millimetres. A geometry's faces are found once, as the pointer first meets each;
// a face's triangles are what the viewer marks the face under the pointer with.

import { Vector3 } from 'three';
import { EDGE_ANGLE_DEG } from './model.js';

/** @import { BufferGeometry, Matrix4, Mesh } from 'three' */
/** @import { Face } from './types.js' */

/** Triangles that face ways this close (the cosine of their angle) are one flat face's. */
const FLAT_COS = Math.cos((0.5 * Math.PI) / 180);
const SMOOTH_COS = Math.cos((EDGE_ANGLE_DEG * Math.PI) / 180);
/** Two corners nearer than this, of the geometry's size, are one point: its triangles meet there. */
const SAME_POINT = 1e-6;
/** Slots in a hash table per key it is given, at least: it stays at most half full. */
const TABLE_ROOM = 2;
/** Odd numbers that spread a key's parts over a hash table's slots. */
const SPREAD = [0x9e3779b1, 0x85ebca77, 0xc2b2ae3d];
/** A face's way is an axis's when this close to it (the cosine). */
const AXIS_COS = Math.cos((1 * Math.PI) / 180);
/** The axes a face may face, and what the views call them. */
const AXES = /** @type {const} */ ([
  { axis: [0, 0, 1], name: '+Z (top)' },
  { axis: [0, 0, -1], name: '-Z (bottom)' },
  { axis: [0, -1, 0], name: '-Y (front)' },
  { axis: [0, 1, 0], name: '+Y (back)' },
  { axis: [1, 0, 0], name: '+X (right)' },
  { axis: [-1, 0, 0], name: '-X (left)' },
]);

/**
 * A geometry's triangles, which meet which across an edge, and the face each was found in (-1
 * for none yet). A triangle's sides are numbered `triangle * 3 + corner`, each from its corner
 * to the next.
 * @typedef {object} Topology
 * @property {Float32Array} normals a unit normal per triangle, 3 numbers each
 * @property {Int32Array} edgeOf the edge each side lies on, by its ends' points
 * @property {Int32Array} start where each edge's sides begin in `sides` (one more, the end)
 * @property {Int32Array} sides the sides on each edge, edge by edge
 * @property {Int32Array} faceOf
 * @property {FaceOf[]} faces
 */

/**
 * A face's triangles, and its area in the scene as last found, with the mesh's matrix it was
 * found for: a pointer moving over the face asks again on every frame.
 * @typedef {object} FaceOf
 * @property {number[]} triangles
 * @property {boolean} flat
 * @property {{ matrix: Matrix4, value: number } | null} area
 */

/** @type {WeakMap<BufferGeometry, Topology>} */
const topologies = new WeakMap();

/**
 * The face of `mesh` its triangle `triangle` is in, in the scene's terms.
 * @param {Mesh} mesh
 * @param {number} triangle the index a raycast's hit gives (`faceIndex`)
 * @returns {Face}
 */
export function faceAt(mesh, triangle) {
  const geometry = mesh.geometry;
  const face = faceContaining(geometry, triangle);
  const area = areaOf(face, geometry, mesh.matrixWorld);
  if (!face.flat) return { flat: false, area, normal: null, facing: null };
  const normal = worldNormal(geometry, triangle, mesh.matrixWorld);
  return {
    flat: true,
    area,
    normal: /** @type {[number, number, number]} */ (normal.toArray()),
    facing: AXES.find(({ axis }) => normal.dot(new Vector3(...axis)) >= AXIS_COS)?.name ?? null,
  };
}

/**
 * The triangles of the face of `mesh` its triangle `triangle` is in: the same array for every
 * triangle of the face (and every mesh of the geometry).
 * @param {Mesh} mesh
 * @param {number} triangle
 * @returns {readonly number[]}
 */
export function faceTriangles(mesh, triangle) {
  return faceContaining(mesh.geometry, triangle).triangles;
}

/**
 * The face of `geometry` its triangle `triangle` is in, found the first time it is asked for.
 * @param {BufferGeometry} geometry
 * @param {number} triangle
 */
function faceContaining(geometry, triangle) {
  let topology = topologies.get(geometry);
  if (!topology) {
    topology = topologyOf(geometry);
    topologies.set(geometry, topology);
  }
  if (topology.faceOf[triangle] < 0) findFace(topology, triangle);
  return topology.faces[topology.faceOf[triangle]];
}

/**
 * The triangles of `geometry`, their normals, and which meet which: across an edge whose two
 * ends each triangle has (by their points, as a mesh's faces each have corners of their own).
 * Typed arrays throughout: a mesh of a million triangles took seconds, a string and an array
 * made for each.
 * @param {BufferGeometry} geometry
 * @returns {Topology}
 */
function topologyOf(geometry) {
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
  for (let side = 0; side < sideCount; side++) {
    const next = side % 3 === 2 ? side - 2 : side + 1;
    const p = pointOf[vertex(side)];
    const q = pointOf[vertex(next)];
    low[side] = Math.min(p, q);
    high[side] = Math.max(p, q);
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
  return {
    normals,
    edgeOf: edges.ids,
    start,
    sides,
    faceOf: new Int32Array(count).fill(-1),
    faces: [],
  };
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

/**
 * Finds the face `seed` is in: the triangles reached across edges that turn less than the
 * feature edges' angle; flat when they all face the seed's way.
 * @param {Topology} topology
 * @param {number} seed
 */
function findFace(topology, seed) {
  const { normals, edgeOf, start, sides, faceOf, faces } = topology;
  const id = faces.length;
  /** @param {number} t @param {number} u */
  const cos = (t, u) =>
    normals[t * 3] * normals[u * 3] +
    normals[t * 3 + 1] * normals[u * 3 + 1] +
    normals[t * 3 + 2] * normals[u * 3 + 2];
  const triangles = [seed];
  faceOf[seed] = id;
  let flat = true;
  for (let at = 0; at < triangles.length; at++) {
    const t = triangles[at];
    for (let side = t * 3; side < t * 3 + 3; side++) {
      const edge = edgeOf[side];
      for (let on = start[edge]; on < start[edge + 1]; on++) {
        const u = Math.floor(sides[on] / 3);
        if (faceOf[u] >= 0 || cos(t, u) < SMOOTH_COS) continue;
        faceOf[u] = id;
        triangles.push(u);
        if (cos(seed, u) < FLAT_COS) flat = false;
      }
    }
  }
  faces.push({ triangles, flat, area: null });
}

/**
 * A triangle's corners, in the scene.
 * @param {BufferGeometry} geometry
 * @param {number} triangle
 * @param {Matrix4} matrix the mesh's to the scene
 * @returns {[Vector3, Vector3, Vector3]}
 */
function corners(geometry, triangle, matrix) {
  const position = geometry.getAttribute('position');
  const index = geometry.getIndex();
  return /** @type {[Vector3, Vector3, Vector3]} */ (
    [0, 1, 2].map((corner) => {
      const i = index ? index.getX(triangle * 3 + corner) : triangle * 3 + corner;
      return new Vector3().fromBufferAttribute(position, i).applyMatrix4(matrix);
    })
  );
}

/**
 * The area of `face` of `geometry` in the scene, by the mesh's `matrix` to it.
 * @param {FaceOf} face
 * @param {BufferGeometry} geometry
 * @param {Matrix4} matrix
 */
function areaOf(face, geometry, matrix) {
  if (face.area?.matrix.equals(matrix)) return face.area.value;
  const position = geometry.getAttribute('position');
  const index = geometry.getIndex();
  /** @param {number} side */
  const vertex = (side) => (index ? index.getX(side) : side);
  const a = new Vector3();
  const b = new Vector3();
  const c = new Vector3();
  let value = 0;
  for (const t of face.triangles) {
    a.fromBufferAttribute(position, vertex(t * 3)).applyMatrix4(matrix);
    b.fromBufferAttribute(position, vertex(t * 3 + 1)).applyMatrix4(matrix);
    c.fromBufferAttribute(position, vertex(t * 3 + 2)).applyMatrix4(matrix);
    value += c.sub(b).cross(a.sub(b)).length() / 2;
  }
  face.area = { matrix: matrix.clone(), value };
  return value;
}

/**
 * @param {BufferGeometry} geometry
 * @param {number} triangle
 * @param {Matrix4} matrix
 */
function worldNormal(geometry, triangle, matrix) {
  const [a, b, c] = corners(geometry, triangle, matrix);
  return c.sub(b).cross(a.sub(b)).normalize();
}
