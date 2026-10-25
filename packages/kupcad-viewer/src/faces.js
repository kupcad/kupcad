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
 * for none yet).
 * @typedef {object} Topology
 * @property {Float32Array} normals a unit normal per triangle, 3 numbers each
 * @property {Int32Array[]} neighbours each triangle's, across its edges
 * @property {Int32Array} faceOf
 * @property {{ triangles: number[], flat: boolean }[]} faces
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
  const area = face.triangles.reduce((sum, t) => sum + worldArea(geometry, t, mesh.matrixWorld), 0);
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
 * corners each triangle has (by their places, as a mesh's faces each have corners of their own).
 * @param {BufferGeometry} geometry
 * @returns {Topology}
 */
function topologyOf(geometry) {
  const position = geometry.getAttribute('position');
  const index = geometry.getIndex();
  const count = (index ? index.count : position.count) / 3;
  geometry.computeBoundingBox();
  const size = geometry.boundingBox?.getSize(new Vector3()).length() || 1;
  const step = size * SAME_POINT;
  /** @param {number} i */
  const pointKey = (i) =>
    `${Math.round(position.getX(i) / step)},${Math.round(position.getY(i) / step)},${Math.round(position.getZ(i) / step)}`;
  /** @param {number} triangle @param {number} corner */
  const vertex = (triangle, corner) =>
    index ? index.getX(triangle * 3 + corner) : triangle * 3 + corner;
  const normals = new Float32Array(count * 3);
  /** @type {Map<string, number[]>} */
  const byEdge = new Map();
  const a = new Vector3();
  const b = new Vector3();
  const c = new Vector3();
  for (let t = 0; t < count; t++) {
    a.fromBufferAttribute(position, vertex(t, 0));
    b.fromBufferAttribute(position, vertex(t, 1));
    c.fromBufferAttribute(position, vertex(t, 2));
    const normal = c.clone().sub(b).cross(a.clone().sub(b)).normalize();
    normals.set([normal.x, normal.y, normal.z], t * 3);
    const keys = [0, 1, 2].map((corner) => pointKey(vertex(t, corner)));
    for (let edge = 0; edge < 3; edge++) {
      const ends = [keys[edge], keys[(edge + 1) % 3]].toSorted().join('|');
      const sharing = byEdge.get(ends);
      if (sharing) sharing.push(t);
      else byEdge.set(ends, [t]);
    }
  }
  /** @type {number[][]} */
  const meeting = Array.from({ length: count }, () => []);
  for (const triangles of byEdge.values()) {
    for (const t of triangles) {
      for (const other of triangles) if (other !== t) meeting[t].push(other);
    }
  }
  return {
    normals,
    neighbours: meeting.map((list) => Int32Array.from(list)),
    faceOf: new Int32Array(count).fill(-1),
    faces: [],
  };
}

/**
 * Finds the face `seed` is in: the triangles reached across edges that turn less than the
 * feature edges' angle; flat when they all face the seed's way.
 * @param {Topology} topology
 * @param {number} seed
 */
function findFace(topology, seed) {
  const { normals, neighbours, faceOf, faces } = topology;
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
    for (const u of neighbours[t]) {
      if (faceOf[u] >= 0 || cos(t, u) < SMOOTH_COS) continue;
      faceOf[u] = id;
      triangles.push(u);
      if (cos(seed, u) < FLAT_COS) flat = false;
    }
  }
  faces.push({ triangles, flat });
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
 * @param {BufferGeometry} geometry
 * @param {number} triangle
 * @param {Matrix4} matrix
 */
function worldArea(geometry, triangle, matrix) {
  const [a, b, c] = corners(geometry, triangle, matrix);
  return c.sub(b).cross(a.sub(b)).length() / 2;
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
