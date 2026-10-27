import { BoxGeometry, BufferGeometry, CylinderGeometry, Float32BufferAttribute, Mesh } from 'three';
import { describe, expect, it } from 'vitest';
import { faceAt, faceTriangles } from './faces.js';

describe('a face', () => {
  it("is the triangles joined where they meet at less than the edges' angle", () => {
    const box = new Mesh(new BoxGeometry(2, 4, 6));
    box.updateMatrixWorld();
    // BoxGeometry's first side, +X, is its first two triangles: 4 × 6 mm
    const side = faceTriangles(box, 0);
    expect([...side].toSorted()).toEqual([0, 1]);
    expect(faceTriangles(box, 1)).toBe(side);
    expect(faceTriangles(box, 2)).not.toBe(side);
    expect(faceAt(box, 1)).toMatchObject({ flat: true, area: 24, facing: '+X (right)' });
  });

  it('is the same for every mesh of the geometry: the copies of a part', () => {
    const geometry = new BoxGeometry(1, 1, 1);
    expect(faceTriangles(new Mesh(geometry), 4)).toBe(faceTriangles(new Mesh(geometry), 4));
  });

  it("is curved where its triangles turn, and its area is its triangles'", () => {
    // A 32-sided prism's side: one face, around; its ends two flat ones
    const sides = 32;
    const prism = new Mesh(new CylinderGeometry(1, 1, 2, sides, 1));
    prism.updateMatrixWorld();
    const side = faceAt(prism, 0);
    expect(side).toMatchObject({ flat: false, normal: null, facing: null });
    expect(faceTriangles(prism, 0)).toHaveLength(sides * 2);
    expect(side.area).toBeCloseTo(sides * 2 * Math.sin(Math.PI / sides) * 2, 5);
    expect(faceAt(prism, sides * 2)).toMatchObject({ flat: true, facing: '+Y (back)' });
  });

  it('joins triangles at their points, not their vertices: a mesh without an index', () => {
    const box = new Mesh(new BoxGeometry(2, 4, 6).toNonIndexed());
    box.updateMatrixWorld();
    expect([...faceTriangles(box, 0)].toSorted()).toEqual([0, 1]);
    expect(faceAt(box, 0)).toMatchObject({ flat: true, area: 24 });
  });

  it('is joined across an edge three triangles meet at only where they turn little', () => {
    // Two triangles in the floor, and a fin standing on the edge they share
    const geometry = new BufferGeometry();
    geometry.setAttribute(
      'position',
      new Float32BufferAttribute(
        [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0.5, 0.5, 1],
        3,
      ),
    );
    const mesh = new Mesh(geometry);
    mesh.updateMatrixWorld();
    expect([...faceTriangles(mesh, 0)].toSorted()).toEqual([0, 1]);
    expect(faceTriangles(mesh, 2)).toEqual([2]);
  });

  it("is measured in the scene, as the mesh's matrix is now", () => {
    const box = new Mesh(new BoxGeometry(2, 4, 6));
    box.updateMatrixWorld();
    expect(faceAt(box, 0).area).toBe(24);
    // Kept while the mesh stays, found again when it moves or grows
    box.position.set(5, 0, 0);
    box.scale.set(1, 2, 3);
    box.updateMatrixWorld();
    expect(faceAt(box, 0).area).toBeCloseTo(24 * 6, 9);
    box.scale.set(1, 1, 1);
    box.updateMatrixWorld();
    expect(faceAt(box, 0).area).toBeCloseTo(24, 9);
  });
});
