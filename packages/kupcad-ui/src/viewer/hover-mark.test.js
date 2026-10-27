import { AdditiveBlending, BoxGeometry, DoubleSide, Mesh, MeshBasicMaterial } from 'three';
import { describe, expect, it } from 'vitest';
import { COPY_GLOW, FACE_GLOW, HoverMark } from './hover-mark.js';

/**
 * The glow under `mesh` of `glow`, if one.
 * @param {Mesh} mesh
 * @param {number} glow
 */
const glowUnder = (mesh, glow) =>
  /** @type {Mesh | undefined} */ (
    mesh.children.find(
      (child) =>
        /** @type {MeshBasicMaterial} */ (/** @type {Mesh} */ (child).material)?.opacity === glow,
    )
  );

describe('HoverMark', () => {
  it('lights the copy up, its face more, adding the colour to theirs, and moves as asked', () => {
    const geometry = new BoxGeometry(2, 2, 2);
    const [first, second] = [new Mesh(geometry), new Mesh(geometry)];
    const mark = new HoverMark('#2f80ed');
    expect(mark.mark(first, 0)).toBe(true);
    const copy = glowUnder(first, COPY_GLOW);
    expect(copy?.geometry).toBe(geometry);
    const face = /** @type {Mesh} */ (glowUnder(first, FACE_GLOW));
    // The +X side's two triangles: every corner at x = 1
    const position = face.geometry.getAttribute('position');
    expect(position.count).toBe(6);
    expect(new Set(position.array.filter((_, i) => i % 3 === 0))).toEqual(new Set([1]));
    for (const material of mark.materials) {
      expect(material).toMatchObject({ blending: AdditiveBlending, depthWrite: false });
      expect(/** @type {MeshBasicMaterial} */ (material).color.getHexString()).toBe('2f80ed');
    }
    // Its other triangle is the same face: no move; another face is
    expect(mark.mark(first, 1)).toBe(false);
    expect(mark.mark(first, 2)).toBe(true);
    // The same face of another copy moves both
    expect(mark.mark(second, 2)).toBe(true);
    expect(first.children).toHaveLength(0);
    expect(second.children).toHaveLength(2);
    // A drawing's shape has no face: its copy alone, on both its sides
    const shape = new Mesh(geometry, new MeshBasicMaterial({ side: DoubleSide }));
    expect(mark.mark(shape, null)).toBe(true);
    expect(shape.children).toHaveLength(1);
    expect(mark.materials[0].side).toBe(DoubleSide);
    expect(mark.mark(null, null)).toBe(true);
    expect(shape.children).toHaveLength(0);
    expect(mark.mark(null, null)).toBe(false);
    mark.setColor('#ff0000');
    expect(/** @type {MeshBasicMaterial} */ (mark.materials[1]).color.getHexString()).toBe(
      'ff0000',
    );
    mark.dispose();
  });
});
