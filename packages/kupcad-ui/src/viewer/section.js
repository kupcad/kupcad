// A section through the model: a plane that every shape's materials clip at, and the faces it
// cuts capped where the plane runs inside a solid, by three.js's stencil technique
// (webgl_clipping_stencil): each solid's back faces count up in the stencil buffer and its front
// faces down, both clipped, so where the count isn't 0 the plane is inside a solid, and a plane
// drawn there in the cap's colour closes the cut.

import {
  AlwaysStencilFunc,
  BackSide,
  DecrementWrapStencilOp,
  DoubleSide,
  FrontSide,
  Group,
  IncrementWrapStencilOp,
  Mesh,
  MeshBasicMaterial,
  MeshStandardMaterial,
  NotEqualStencilFunc,
  Plane,
  PlaneGeometry,
  ReplaceStencilOp,
  Vector3,
} from 'three';
import { ownMaterials } from './model.js';

/** @import { Material, Sphere } from 'three' */
/** @import { Section, SceneModel, Theme } from './types.js' */

/**
 * The order things are drawn in: the stencil counts, the cap where they say the plane is inside
 * a solid, then the model (always last, the others drawn only while a section is on).
 */
export const RENDER_ORDER = { stencil: 1, cap: 1.1, model: 2 };
/** The axis each section is across, as the direction it cuts away. */
const AXES = { x: new Vector3(1, 0, 0), y: new Vector3(0, 1, 0), z: new Vector3(0, 0, 1) };
/** The cap plane reaches this far past the model's bounding sphere's radius. */
const CAP_REACH = 4;
const PLANE_NORMAL = new Vector3(0, 0, 1);

export class SectionView {
  /** The plane every material clips at, while a section is on. */
  plane = new Plane();
  /** Whether the model is cut: a section is on, and the model is a solid's (a drawing isn't). */
  clipping = false;
  /** The cap's plane, drawn where the stencil count isn't 0. */
  cap;
  /** The stencil counters added under each solid mesh: taken away with the section. */
  #counters = /** @type {Group[]} */ ([]);
  /** The model they count for: a section moved over it keeps them. @type {SceneModel | null} */
  #counted = null;
  /** The counters' back faces count up, their front faces down; every counter shares these. */
  #counting = [
    counterMaterial(BackSide, IncrementWrapStencilOp, this.plane),
    counterMaterial(FrontSide, DecrementWrapStencilOp, this.plane),
  ];

  /** @param {Theme} theme */
  constructor(theme) {
    const material = new MeshStandardMaterial({
      color: theme.cap,
      // Seen from the side cut away, against the plane's normal, which points to what is kept
      side: DoubleSide,
      stencilWrite: true,
      stencilRef: 0,
      stencilFunc: NotEqualStencilFunc,
      stencilFail: ReplaceStencilOp,
      stencilZFail: ReplaceStencilOp,
      stencilZPass: ReplaceStencilOp,
    });
    this.cap = new Mesh(new PlaneGeometry(1, 1), material);
    this.cap.renderOrder = RENDER_ORDER.cap;
    this.cap.visible = false;
  }

  /** @param {string} color */
  setCapColor(color) {
    /** @type {MeshStandardMaterial} */ (this.cap.material).color.set(color);
  }

  /**
   * Cuts `model` at `section`, or takes the cut away (null). A section moved over the same
   * model moves the plane alone: its counters stay, and the materials' programs (a material
   * clipping, or not, is a program of its own), where every move of the offset made them again.
   * @param {Section | null} section
   * @param {SceneModel | null} model
   * @param {Sphere} bounds the model's, which the cap must cover
   * @param {{ capped: boolean, also: Material[] }} options whether the cut is closed (not in a
   *   wireframe), and materials outside the model that clip with it (the selected shapes'
   *   edges)
   */
  apply(section, model, bounds, { capped, also }) {
    const cut = section && model?.kind === '3d' ? { section, model } : null;
    this.clipping = cut !== null;
    if (cut) {
      // What lies past the offset, along the axis (against it when flipped), is cut away
      this.plane.normal.copy(AXES[cut.section.axis]).multiplyScalar(cut.section.flip ? 1 : -1);
      this.plane.constant = cut.section.flip ? -cut.section.offset : cut.section.offset;
    }
    this.cap.visible = cut !== null && capped;
    for (const material of [...(model ? ownMaterials(model) : []), ...also]) {
      const clips = material.clippingPlanes !== null && material.clippingPlanes.length > 0;
      if (clips === this.clipping) continue;
      material.clippingPlanes = this.clipping ? [this.plane] : null;
      material.needsUpdate = true;
    }
    this.#count(cut && capped ? cut.model : null);
    if (!cut || !capped) return;
    // Centred where the model's centre meets the plane, the cap covers the cut wherever it is
    const size = bounds.radius * CAP_REACH;
    this.cap.scale.set(size, size, 1);
    this.plane.projectPoint(bounds.center, this.cap.position);
    this.cap.quaternion.setFromUnitVectors(PLANE_NORMAL, this.plane.normal);
  }

  dispose() {
    this.cap.geometry.dispose();
    /** @type {Material} */ (this.cap.material).dispose();
    for (const material of this.#counting) material.dispose();
  }

  /**
   * Puts the stencil counters under the solid meshes of `model`, or takes them away (null):
   * the ones there already stay.
   * @param {SceneModel | null} model
   */
  #count(model) {
    if (model === this.#counted) return;
    for (const counters of this.#counters) counters.removeFromParent();
    this.#counters = [];
    this.#counted = model;
    for (const shape of model?.shapes ?? []) {
      if (shape.ghost) continue;
      const counters = new Group();
      for (const material of this.#counting) {
        const counter = new Mesh(shape.mesh.geometry, material);
        counter.renderOrder = RENDER_ORDER.stencil;
        counters.add(counter);
      }
      shape.mesh.add(counters);
      this.#counters.push(counters);
    }
  }
}

/**
 * The material of a stencil counter, an invisible copy of a solid clipped at `plane`: its
 * faces on `side` change the count by `op`.
 * @param {import('three').Side} side
 * @param {import('three').StencilOp} op
 * @param {Plane} plane
 * @returns {MeshBasicMaterial}
 */
function counterMaterial(side, op, plane) {
  return new MeshBasicMaterial({
    side,
    clippingPlanes: [plane],
    depthWrite: false,
    depthTest: false,
    colorWrite: false,
    stencilWrite: true,
    stencilFunc: AlwaysStencilFunc,
    stencilFail: op,
    stencilZFail: op,
    stencilZPass: op,
  });
}
