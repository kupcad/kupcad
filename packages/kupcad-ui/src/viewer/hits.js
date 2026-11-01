// What a ray meets among a model's meshes, through a bounds tree of each geometry
// (three-mesh-bvh), made the first time a ray is cast at it: three.js's own raycast tests every
// triangle, 14 ms a pointer move at 500k triangles. The tree is indirect, so the geometry's
// index stays as it is and a hit's `faceIndex` is the triangle the faces (faces.js) know.

import { MeshBVH } from 'three-mesh-bvh';

/** @import { BufferGeometry, Intersection, Mesh, Raycaster } from 'three' */

/** @type {WeakMap<BufferGeometry, MeshBVH>} */
const trees = new WeakMap();

/**
 * The hits of `raycaster`'s ray on `meshes` (not their children), nearest first, as
 * `raycaster.intersectObjects(meshes, false)` gives them.
 * @param {Raycaster} raycaster
 * @param {Mesh[]} meshes
 * @returns {Intersection[]}
 */
export function intersectMeshes(raycaster, meshes) {
  /** @type {Intersection[]} */
  const hits = [];
  for (const mesh of meshes) {
    if (!mesh.layers.test(raycaster.layers)) continue;
    treeOf(mesh.geometry).raycastObject3D(mesh, raycaster, hits);
  }
  return hits.toSorted((a, b) => a.distance - b.distance);
}

/**
 * @param {BufferGeometry} geometry
 * @returns {MeshBVH}
 */
function treeOf(geometry) {
  let tree = trees.get(geometry);
  if (!tree) {
    tree = new MeshBVH(geometry, { indirect: true });
    trees.set(geometry, tree);
  }
  return tree;
}
