// What the pointer is over, marked: the copy under it glows a little in the selection's colour,
// and on a solid the face under it (its triangles, faces.js) more. Each is a mesh under the
// copy's, adding light to what is drawn there, so the mark shows on a part of any colour (a tint
// toward the selection's lost itself in a part of that colour), and a little in front of the
// faces, which are drawn behind their own depth (model.js). The viewer moves it as the pointer
// goes.

import {
  AdditiveBlending,
  BufferGeometry,
  Float32BufferAttribute,
  Mesh,
  MeshBasicMaterial,
} from 'three';
import { faceTriangles } from './faces.js';

/** @import { Material } from 'three' */

/** How much of the selection's colour the copy under the pointer takes on, and its face. */
export const COPY_GLOW = 0.2;
export const FACE_GLOW = 0.4;
/** What a mark draws while it marks nothing. */
const NOTHING = new BufferGeometry();

export class HoverMark {
  #copy = new Mesh(NOTHING, glowMaterial(COPY_GLOW));
  #face = new Mesh(NOTHING, glowMaterial(FACE_GLOW));
  /** The copy marked, or null. @type {Mesh | null} */
  #mesh = null;
  /** Its face marked: faces.js's array of the face's triangles, or null. @type {readonly number[] | null} */
  #triangles = null;

  /** @param {string} color a CSS colour */
  constructor(color) {
    this.setColor(color);
  }

  /** Its materials: the viewer clips them at a section, as the model's. @returns {Material[]} */
  get materials() {
    return [
      /** @type {Material} */ (this.#copy.material),
      /** @type {Material} */ (this.#face.material),
    ];
  }

  /** @param {string} color a CSS colour */
  setColor(color) {
    for (const material of this.materials)
      /** @type {MeshBasicMaterial} */ (material).color.set(color);
  }

  /**
   * Marks `mesh`, a copy, and the face its triangle `triangle` is in (none: null); nothing for
   * a null mesh.
   * @param {Mesh | null} mesh
   * @param {number | null} triangle
   * @returns {boolean} whether the mark moved
   */
  mark(mesh, triangle) {
    const triangles = mesh && triangle !== null ? faceTriangles(mesh, triangle) : null;
    if (mesh === this.#mesh && triangles === this.#triangles) return false;
    if (mesh !== this.#mesh) {
      this.#copy.removeFromParent();
      this.#mesh = mesh;
      // The copy's own geometry, drawn on the side its faces are (a drawing's, both)
      this.#copy.geometry = mesh ? mesh.geometry : NOTHING;
      if (mesh) {
        const material = /** @type {Material} */ (this.#copy.material);
        const { side } = /** @type {Material} */ (mesh.material);
        if (material.side !== side) {
          material.side = side;
          material.needsUpdate = true;
        }
        mesh.add(this.#copy);
      }
    }
    this.#face.removeFromParent();
    if (this.#face.geometry !== NOTHING) this.#face.geometry.dispose();
    this.#triangles = triangles;
    this.#face.geometry = mesh && triangles ? trianglesOf(mesh, triangles) : NOTHING;
    if (mesh && triangles) mesh.add(this.#face);
    return true;
  }

  dispose() {
    this.mark(null, null);
    for (const material of this.materials) material.dispose();
  }
}

/**
 * What adds `glow` of its colour to what is drawn under it, a little in front of the faces.
 * @param {number} glow
 * @returns {MeshBasicMaterial}
 */
function glowMaterial(glow) {
  return new MeshBasicMaterial({
    transparent: true,
    opacity: glow,
    blending: AdditiveBlending,
    depthWrite: false,
    polygonOffset: true,
    polygonOffsetFactor: -1,
    polygonOffsetUnits: -1,
  });
}

/**
 * The triangles of `mesh` listed, as a geometry of their own in the mesh's space.
 * @param {Mesh} mesh
 * @param {readonly number[]} triangles
 * @returns {BufferGeometry}
 */
function trianglesOf(mesh, triangles) {
  const position = mesh.geometry.getAttribute('position');
  const index = mesh.geometry.getIndex();
  const positions = new Float32Array(triangles.length * 9);
  triangles.forEach((triangle, at) => {
    for (let corner = 0; corner < 3; corner++) {
      const i = index ? index.getX(triangle * 3 + corner) : triangle * 3 + corner;
      positions.set([position.getX(i), position.getY(i), position.getZ(i)], at * 9 + corner * 3);
    }
  });
  return new BufferGeometry().setAttribute('position', new Float32BufferAttribute(positions, 3));
}
