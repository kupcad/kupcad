// A mesh's faces, as its feature edges bound them: the triangles joined across their edges where
// they don't turn (topology.js; model.js draws an edge where they do). A face
// is flat when its triangles all face one way, curved otherwise (a cylinder's side); its area is
// in the scene's millimetres. A geometry's faces are found once, as the pointer first meets each;
// a face's triangles are what the viewer marks the face under the pointer with.

import { Vector3 } from 'three';
import { topologyOf, turns } from './topology.js';

/** @import { BufferGeometry, Matrix4, Mesh } from 'three' */
/** @import { Face } from './types.js' */
/** @import { Topology } from './topology.js' */

/** Triangles that face ways this close (the cosine of their angle) are one flat face's. */
const FLAT_COS = Math.cos((0.5 * Math.PI) / 180);
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
 * A geometry's faces as found so far: the face each triangle was found in (-1 for none yet).
 * @typedef {object} Faces
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

/** @type {WeakMap<BufferGeometry, Faces>} */
const found = new WeakMap();

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
  const topology = topologyOf(geometry);
  let faces = found.get(geometry);
  if (!faces) {
    faces = { faceOf: new Int32Array(topology.normals.length / 3).fill(-1), faces: [] };
    found.set(geometry, faces);
  }
  if (faces.faceOf[triangle] < 0) findFace(topology, faces, triangle);
  return faces.faces[faces.faceOf[triangle]];
}

/**
 * Finds the face `seed` is in: the triangles reached across edges that don't turn; flat when
 * they all face the seed's way.
 * @param {Topology} topology
 * @param {Faces} found the faces found so far, which it joins
 * @param {number} seed
 */
function findFace(topology, { faceOf, faces }, seed) {
  const { normals, edgeOf, start, sides } = topology;
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
        if (faceOf[u] >= 0 || turns(topology, t, u)) continue;
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
