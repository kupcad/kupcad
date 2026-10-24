// Freeing the GPU's copies of what the viewer drew: three.js keeps a geometry's buffers and a
// material's program until they are disposed, however long ago their objects left the scene.

import { LineSegments, Mesh } from 'three';

/** @import { Object3D } from 'three' */

/**
 * Frees the geometries of the meshes and lines under `root`.
 * @param {Object3D} root
 */
export function disposeGeometries(root) {
  root.traverse((object) => {
    if (object instanceof Mesh || object instanceof LineSegments) object.geometry.dispose();
  });
}

/**
 * Frees the geometries and the materials of the meshes and lines under `root`, which owns them
 * all.
 * @param {Object3D} root
 */
export function disposeObject(root) {
  disposeGeometries(root);
  root.traverse((object) => {
    if (object instanceof Mesh || object instanceof LineSegments) {
      for (const material of [object.material].flat()) material.dispose();
    }
  });
}
