import { describe, expect, it } from 'vitest';
import { Mesh, MeshBasicMaterial, Raycaster, SphereGeometry, Vector3 } from 'three';
import { intersectMeshes } from './hits.js';

/**
 * A sphere of radius 1 at `x`, scaled by 2.
 * @param {number} x
 */
function sphere(x) {
  const mesh = new Mesh(new SphereGeometry(1, 32, 16), new MeshBasicMaterial());
  mesh.position.x = x;
  mesh.scale.setScalar(2);
  mesh.updateMatrixWorld();
  return mesh;
}

/** A ray along -z through (x, y). */
function rayAt(/** @type {number} */ x, /** @type {number} */ y) {
  return new Raycaster(new Vector3(x, y, 10), new Vector3(0, 0, -1));
}

describe('intersectMeshes', () => {
  it("hits what three.js's raycast hits: the same triangles, as far, in the scene's terms", () => {
    const mesh = sphere(3);
    const index = Array.from(
      /** @type {import('three').BufferAttribute} */ (mesh.geometry.index).array,
    );
    for (const [x, y] of [
      [3, 0],
      [4.2, 0.7],
      [2.1, -1.3],
      [3, 1.99],
    ]) {
      const raycaster = rayAt(x, y);
      const ours = intersectMeshes(raycaster, [mesh]);
      const three = raycaster.intersectObject(mesh, false);
      expect(ours.length).toBe(three.length);
      expect(ours.length).toBeGreaterThan(0);
      ours.forEach((hit, i) => {
        expect(hit.faceIndex).toBe(three[i].faceIndex);
        expect(hit.distance).toBeCloseTo(three[i].distance, 9);
        expect(hit.object).toBe(mesh);
      });
    }
    // The faces know triangles by the geometry's index, which the tree leaves as it was
    expect(
      Array.from(/** @type {import('three').BufferAttribute} */ (mesh.geometry.index).array),
    ).toEqual(index);
  });

  it('gives the hits of several meshes nearest first (a front face each), and none past them', () => {
    const near = sphere(0);
    near.position.z = 4;
    near.updateMatrixWorld();
    const far = sphere(0);
    const hits = intersectMeshes(rayAt(0, 0), [far, near]);
    expect(hits.map((hit) => hit.object)).toEqual([near, far]);
    expect(intersectMeshes(rayAt(9, 9), [far, near])).toEqual([]);
  });

  it('leaves out a mesh on a layer the ray does not see', () => {
    const mesh = sphere(0);
    mesh.layers.set(3);
    expect(intersectMeshes(rayAt(0, 0), [mesh])).toEqual([]);
  });
});
