import { BoxGeometry, Mesh } from 'three';
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
});
